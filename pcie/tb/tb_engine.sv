// Equivalence testbench: the parallel engine (pcie/rtl/bitacc_engine.sv) against
// the single-op reference core (rtl/bit_accelerator.sv).
//
// Both start from the same random memory image and receive the same operation
// stream. The reference core runs the stream one operation at a time, range
// operations expanded into single-bit operations (tb/gold_ops.svh); the
// engine gets it as a stream with random gaps and random result backpressure.
// Every result (error flag; bit and value when there is no error) and every
// word of the final memory must match. Exits non-zero on any mismatch, or if
// a coverage goal (operation classes, out-of-order completion, full reorder
// buffer, range barriers in both directions) was not reached.
//
//   +ops=N +seed=N        stream length and seed
//   -DLANES=n -DWPL=n     engine geometry (default 4 lanes x 16 words: many conflicts)
`timescale 1ns/1ps
module tb_engine;
`ifndef LANES
  `define LANES 4
`endif
`ifndef WPL
  `define WPL 16
`endif
`ifndef MATCH
  `define MATCH 1
`endif
  localparam int LANES = `LANES;
  localparam int WPL   = `WPL;
  localparam int WORDS = LANES * WPL;
  localparam bit WITH_MATCH = `MATCH;
  localparam int MAXOPS = 20000;

  logic clk = 1'b0, reset = 1'b1;
  always #5 clk = ~clk;

  integer checks = 0, fails = 0;
  task automatic check(input bit cond, input string what);
    checks++;
    if (!cond) begin
      fails++;
      if (fails <= 20) $display("FAIL @%0t: %s", $time, what);
    end
  endtask

  // ------------------------------------------------------------ stimulus
  integer ops = 5000, seed = 1, seed0;
  logic [3:0]  s_op  [MAXOPS];
  logic [63:0] s_base[MAXOPS], s_off[MAXOPS];
  logic [31:0] s_len [MAXOPS];
  logic [23:0] s_src [MAXOPS];
  logic [2:0]  s_fn  [MAXOPS];
  logic        s_dry [MAXOPS];
  logic [63:0] init  [WORDS];

  // xorshift32, well distributed in every simulator. (Verilator 5.020's
  // seeded system random function is degenerate: the seed roughly doubles on
  // every call.) Simulators may evaluate operands such as rnd(a) + rnd(b) in
  // different orders, so the same seed can give different streams in Icarus
  // and Verilator; each is checked the same way.
  function automatic logic [31:0] rnd32();
    logic [31:0] x;
    x = (seed == 0) ? 32'd1 : 32'(seed);
    x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
    seed = x;
    rnd32 = x;
  endfunction
  function automatic integer rnd(input integer n);
    rnd = (n <= 1) ? 0 : integer'(rnd32() % 32'(n));
  endfunction

  // ------------------------------------------------------------ reference: core + memory
  logic        g_op_valid = 1'b0, g_op_ready;
  logic [63:0] g_base = '0, g_off = '0;
  logic [2:0]  g_opc = '0;
  logic        g_res_valid, g_res_bit, g_error;
  logic        g_mem_valid, g_mem_write;
  logic [63:0] g_mem_addr, g_mem_wdata;
  logic [7:0]  g_mem_wstrb;
  logic        g_mem_rvalid = 1'b0, g_mem_fault = 1'b0;
  logic [63:0] g_mem_rdata = '0;
  logic [63:0] gmem [WORDS];

  bit_accelerator gold (
    .clk, .reset,
    .op_valid(g_op_valid), .op_ready(g_op_ready),
    .base_address(g_base), .bit_offset(g_off), .operation(g_opc),
    .result_valid(g_res_valid), .result_bit(g_res_bit), .error(g_error),
    .mem_valid(g_mem_valid), .mem_write(g_mem_write), .mem_addr(g_mem_addr),
    .mem_wdata(g_mem_wdata), .mem_wstrb(g_mem_wstrb),
    .mem_ready(1'b1), .mem_rvalid(g_mem_rvalid), .mem_rdata(g_mem_rdata),
    .mem_fault(g_mem_fault));

  // Memory slave for the reference: byte addresses 0 .. WORDS*8-1, else fault.
  always @(posedge clk) begin
    g_mem_rvalid <= 1'b0;
    g_mem_fault  <= 1'b0;
    if (!reset && g_mem_valid) begin
      if ((g_mem_addr >> 3) >= WORDS) g_mem_fault <= 1'b1;
      else if (g_mem_write) gmem[g_mem_addr >> 3] <= g_mem_wdata;
      else begin g_mem_rvalid <= 1'b1; g_mem_rdata <= gmem[g_mem_addr >> 3]; end
    end
  end

  logic        g_err_r [MAXOPS];
  logic        g_bit_r [MAXOPS];
  logic [55:0] g_val_r [MAXOPS];
  bit   gold_done = 0;

  `include "gold_ops.svh"
  `include "range_stim.svh"

  task automatic run_gold();
    logic e, b;
    logic [55:0] v;
    for (int n = 0; n < ops; n++) begin
      if (s_op[n] < 4'd8) begin
        gold_op(s_base[n], s_off[n], s_op[n][2:0], e, b);
        v = '0;
      end else
        gold_range(s_op[n], (s_base[n] << 3) + s_off[n], s_len[n], s_src[n], s_fn[n], s_dry[n], e, b, v);
      g_err_r[n] = e;
      g_bit_r[n] = b;
      g_val_r[n] = v;
    end
    gold_done = 1;
  endtask

  // ------------------------------------------------------------ engine
  logic        cmd_valid = 1'b0, cmd_ready;
  logic [3:0]  cmd_op = '0;
  logic [63:0] cmd_base = '0, cmd_offset = '0;
  logic [31:0] cmd_len = '0;
  logic [23:0] cmd_src = '0;
  logic [2:0]  cmd_fn = '0;
  logic        cmd_dry = 1'b0;
  logic        res_valid, res_ready = 1'b0, res_error, res_bit;
  logic [55:0] res_value;
  logic        host_valid = 1'b0, host_ready, host_write = 1'b0, host_rvalid;
  logic [$clog2(WORDS)-1:0] host_word = '0;
  logic [63:0] host_wdata = '0, host_rdata;
  logic        idle;

  bitacc_engine #(.LANES(LANES), .WORDS_PER_LANE(WPL), .WITH_MATCH(WITH_MATCH)) dut (.*);

  logic        e_err_r [MAXOPS];
  logic        e_bit_r [MAXOPS];
  logic [55:0] e_val_r [MAXOPS];
  integer e_results = 0;
  bit   eng_done = 0;

  // result sink with random backpressure
  always @(posedge clk) begin
    if (!reset && res_valid && res_ready) begin
      e_err_r[e_results] <= res_error;
      e_bit_r[e_results] <= res_bit;
      e_val_r[e_results] <= res_value;
      e_results <= e_results + 1;
    end
  end
  // Random backpressure, plus a 200-cycle stall every 2000 cycles that fills
  // the reorder buffer and must hold the engine at its in-flight limit.
  integer sink_cyc = 0;
  always @(negedge clk) begin
    sink_cyc <= sink_cyc + 1;
    res_ready <= ((sink_cyc % 2000) >= 200) && ((rnd32() % 4) != 0);
  end

  task automatic host_write_word(input integer w, input logic [63:0] v);
    @(negedge clk);
    host_valid = 1'b1; host_write = 1'b1; host_word = w; host_wdata = v;
    while (!host_ready) @(negedge clk);
    @(negedge clk); host_valid = 1'b0; host_write = 1'b0;
  endtask

  task automatic host_read_word(input integer w, output logic [63:0] v);
    @(negedge clk);
    host_valid = 1'b1; host_write = 1'b0; host_word = w;
    while (!host_ready) @(negedge clk);
    @(negedge clk); host_valid = 1'b0;
    check(host_rvalid === 1'b1, "host_rvalid one cycle after a read handshake");
    v = host_rdata;
  endtask

  task automatic run_engine();
    integer n = 0;
    while (n < ops) begin
      @(negedge clk);
      if (rnd(20) == 0) cmd_valid = 1'b0;                   // input gap
      else begin
        // cmd_ready does not depend on cmd_valid and only changes on a rising
        // edge, so its value now is the one the engine samples at the next edge.
        cmd_valid = 1'b1; cmd_op = s_op[n]; cmd_base = s_base[n]; cmd_offset = s_off[n];
        cmd_len = s_len[n]; cmd_src = s_src[n]; cmd_fn = s_fn[n]; cmd_dry = s_dry[n];
        if (cmd_ready) n++;
      end
    end
    @(negedge clk); cmd_valid = 1'b0;
    while (e_results < ops) @(negedge clk);
    eng_done = 1;
  endtask

  // ------------------------------------------------------------ coverage, watchdog
  // A completion is out of order when an older operation (between the reorder
  // head and its own slot) has not completed yet. Shadow completion flags per
  // reorder slot: set when a result is written, cleared when it is emitted.
  integer ooo = 0, idle_cycles = 0, last_results = 0, rob_full_cycles = 0;
  integer range_waits = 0, single_waits = 0;   // barrier: range behind lanes, single behind range
  bit older_pending;
  bit cdone [32];
  initial for (int i = 0; i < 32; i++) cdone[i] = 0;
  // Sampled mid-cycle: the engine's registers are stable and hold exactly the
  // values the next rising edge consumes, independent of simulator ordering.
  always @(negedge clk) begin
    if (!reset) begin
      if (dut.inflight == 32) rob_full_cycles <= rob_full_cycles + 1;
      if (dut.d_valid && !dut.d_err && dut.d_range && dut.ops_out != '0) range_waits <= range_waits + 1;
      if (dut.d_valid && !dut.d_err && !dut.d_range && dut.r_busy) single_waits <= single_waits + 1;
      for (int i = 0; i < LANES; i++)
        if (dut.l_done[i]) begin
          older_pending = 0;
          for (int t = dut.head; (t % 32) != dut.l_seq[i]; t++)
            if (!cdone[t % 32]) older_pending = 1;
          if (older_pending) ooo = ooo + 1;
        end
      for (int i = 0; i < LANES; i++) if (dut.l_done[i]) cdone[dut.l_seq[i]] = 1;
      if (dut.d_take && dut.d_err) cdone[dut.d_seq] = 1;
      if (dut.r_done) cdone[dut.r_seq] = 1;
      if (res_valid && res_ready) cdone[dut.head] = 0;
      if (e_results != last_results || dut.idle) idle_cycles <= 0;
      else idle_cycles <= idle_cycles + 1;
      last_results <= e_results;
      if (idle_cycles > 20000) $fatal(1, "engine stalled: no result for 20000 cycles");
      if (dut.inflight > 32) $fatal(1, "more operations in flight than reorder slots");
    end
  end

  // ------------------------------------------------------------ main
  logic [63:0] v;
  integer kind;                                // per-operation stimulus class
  integer pend_i = 0;                          // next entry of a pending MATCH sequence
  integer n_hot = 0, n_any = 0, n_past = 0, n_wrap = 0, n_undef = 0, n_range = 0;
  logic [63:0] ra;

  // Bit-store-wide operations at fixed points of the stream.
  task automatic gen_whole(input int n, input int which);
    s_base[n] = 0; s_off[n] = 0; s_src[n] = 0; s_fn[n] = 3'd3; s_dry[n] = 1'b0;
    case (which)
      0: begin s_op[n] = R_COUNT; s_len[n] = WORDS * 64; end
      1: begin s_op[n] = R_FLIPR; s_len[n] = WORDS * 64; end
      default: begin s_op[n] = R_BULK; s_len[n] = WORDS / 2; s_off[n] = WORDS / 2; end   // upper ^= lower
    endcase
  endtask
  initial begin
    if (!$value$plusargs("ops=%d", ops)) ops = 5000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    seed0 = seed;
    if (ops > MAXOPS) ops = MAXOPS;

    for (int w = 0; w < WORDS; w++) begin
      init[w] = {rnd32(), rnd32()};
      gmem[w] = init[w];
    end
    for (int n = 0; n < ops; n++) begin
      // Blocks of 24: 16 back-to-back operations on 4 words of lane 0 (its queue
      // builds up), then 8 mixed ones, many of which overtake them in other lanes.
      kind = ((n % 24) < 16) ? 0 : 40 + rnd(60);
      s_op[n] = (rnd(12) == 0) ? 4'(5 + rnd(3)) : 4'(rnd(5));
      s_len[n] = '0; s_src[n] = '0; s_fn[n] = '0; s_dry[n] = 1'b0;
      if (s_op[n] > 4'd4) n_undef++;
      if (n == ops / 4 || n == ops / 2 || n == 3 * ops / 4) begin
        n_range++;
        gen_whole(n, n == ops / 4 ? 0 : n == ops / 2 ? 1 : 2);
      end else if (pend_i < rs_q_n || (kind >= 40 && rnd(4) == 0)) begin   // range operation
        n_range++;
        if (pend_i < rs_q_n) begin                   // rest of a MATCH sequence
          s_op[n] = rs_q_op[pend_i]; ra = rs_q_a[pend_i]; s_len[n] = rs_q_len[pend_i];
          s_src[n] = rs_q_src[pend_i]; s_fn[n] = rs_q_fn[pend_i]; pend_i++;
        end else if (rnd(4) == 0) begin
          gen_match_seq();
          s_op[n] = rs_q_op[0]; ra = rs_q_a[0]; s_len[n] = rs_q_len[0];
          s_src[n] = rs_q_src[0]; s_fn[n] = rs_q_fn[0]; pend_i = 1;
        end else
          gen_range(s_op[n], ra, s_len[n], s_src[n], s_fn[n], s_dry[n]);
        if (rnd(2) == 0) begin s_base[n] = 0; s_off[n] = ra; end
        else begin s_base[n] = ra >> 3; s_off[n] = ra & 64'd7; end
      end else if (kind < 40) begin                       // hot spot: 4 words, all in lane 0
        n_hot++;
        s_base[n] = rnd(4) * LANES * 8; s_off[n] = rnd(64);
      end else if (kind < 80) begin              // anywhere in memory
        n_any++;
        s_base[n] = rnd(WORDS * 8); s_off[n] = rnd(64 * 4);
        if (rnd(2) == 0) s_base[n] = (rnd(WPL) * LANES + 1 + rnd(LANES - 1)) * 8;  // not lane 0
      end else if (kind < 95) begin              // just past the end
        n_past++;
        s_base[n] = WORDS * 8 + rnd(16); s_off[n] = rnd(64);
      end else begin                             // arbitrary 64-bit values (wraps)
        n_wrap++;
        s_base[n] = {rnd32(), rnd32()}; s_off[n] = {rnd32(), rnd32()};
      end
    end

    $display("stimulus: hot=%0d anywhere=%0d past_end=%0d wrap=%0d undefined_op=%0d range=%0d",
             n_hot, n_any, n_past, n_wrap, n_undef, n_range);
    check(n_hot > ops / 3 && n_any > ops / 20 && n_past > ops / 80 && n_wrap > ops / 400
          && n_undef > ops / 40 && n_range > ops / 40, "stimulus covers every operation class");
    repeat (3) @(negedge clk);
    reset = 1'b0;
    for (int w = 0; w < WORDS; w++) host_write_word(w, init[w]);
    for (int w = 0; w < WORDS; w++) begin
      host_read_word(w, v);
      check(v === init[w], $sformatf("host read back word %0d", w));
    end

    fork
      run_gold();
      run_engine();
    join

    for (int n = 0; n < ops; n++) begin
      check(e_err_r[n] === g_err_r[n],
            $sformatf("op %0d (%0d, base %h, off %h, len %0d, src %0d, fn %0d): error %b, reference %b",
                      n, s_op[n], s_base[n], s_off[n], s_len[n], s_src[n], s_fn[n], e_err_r[n], g_err_r[n]));
      if (!g_err_r[n])
        check(e_bit_r[n] === g_bit_r[n] && e_val_r[n] === g_val_r[n],
              $sformatf("op %0d (%0d, base %h, off %h, len %0d, src %0d, fn %0d): bit %b value %0d, reference %b %0d",
                        n, s_op[n], s_base[n], s_off[n], s_len[n], s_src[n], s_fn[n],
                        e_bit_r[n], e_val_r[n], g_bit_r[n], g_val_r[n]));
      else
        check(e_bit_r[n] === 1'b0 && e_val_r[n] === '0, $sformatf("op %0d: error result has bit 0, value 0", n));
      range_cover(s_op[n], (s_base[n] << 3) + s_off[n], s_len[n], s_src[n], s_fn[n], s_dry[n],
                  g_err_r[n], g_bit_r[n]);
    end
    range_cover_check();
    check(range_waits > 0, "a range operation waited for busy lanes");
    check(single_waits > 0, "an operation waited for a running range operation");
    check(idle, "engine idle after the stream");
    check(ooo > ops / 50, $sformatf("out-of-order completions exercised (%0d)", ooo));
    check(rob_full_cycles > 0, "reorder buffer filled (in-flight limit exercised)");
    for (int w = 0; w < WORDS; w++) begin
      host_read_word(w, v);
      check(v === gmem[w], $sformatf("final word %0d: %h, reference %h", w, v, gmem[w]));
    end

    $display("checks=%0d fails=%0d lanes=%0d words=%0d ops=%0d seed=%0d out_of_order=%0d rob_full=%0d range_waits=%0d single_waits=%0d reference_ops=%0d",
             checks, fails, LANES, WORDS, ops, seed0, ooo, rob_full_cycles, range_waits, single_waits, gold_ops_issued);
    if (fails != 0) $fatal(1, "FAIL");
    $display("PASS: engine matches the reference core");
    $finish;
  end

  initial begin
    repeat (20) #1_000_000_000;
    $fatal(1, "global timeout");
  end
endmodule
