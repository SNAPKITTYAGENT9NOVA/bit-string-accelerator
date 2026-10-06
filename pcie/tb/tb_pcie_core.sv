// bitacc_pcie_core (128-bit descriptor/result streams + register interface)
// against the single-op reference core rtl/bit_accelerator.sv.
//
// The reference executes each single-bit descriptor as base = 0, offset = bit
// address, and each range descriptor as its expansion into single-bit
// operations (tb/gold_ops.svh). The stream side sees input gaps and output
// backpressure with long stalls. Every 8-byte result, the counters, the idle
// flag and the final memory (read through the register interface) must
// match, and every range class must occur (tb/range_stim.svh). Exits non-zero
// on any mismatch.
`timescale 1ns/1ps
module tb_pcie_core;
`ifndef LANES
  `define LANES 4
`endif
`ifndef WPL
  `define WPL 16
`endif
  localparam int LANES = `LANES;
  localparam int WPL   = `WPL;
  localparam int WORDS = LANES * WPL;
  localparam int MAXOPS = 16384;

  logic clk = 1'b0, reset = 1'b1;
  always #4 clk = ~clk;                 // 125 MHz

  integer checks = 0, fails = 0;
  task automatic check(input bit cond, input string what);
    checks++;
    if (!cond) begin
      fails++;
      if (fails <= 20) $display("FAIL @%0t: %s", $time, what);
    end
  endtask

  integer seed = 3, seed0, ops = 3200;
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

  // ------------------------------------------------------------ stimulus
  logic [3:0]  s_op  [MAXOPS];
  logic [63:0] s_bit [MAXOPS];       // a: bit address, or dst word for BULK
  logic [31:0] s_len [MAXOPS];
  logic [23:0] s_src [MAXOPS];
  logic [2:0]  s_fn  [MAXOPS];
  logic        s_dry [MAXOPS];
  logic [63:0] init  [WORDS];

  // ------------------------------------------------------------ reference
  logic        g_op_valid = 1'b0, g_op_ready;
  logic [63:0] g_base = '0, g_off = '0;
  logic [2:0]  g_opc = '0;
  logic        g_res_valid, g_res_bit, g_error;
  logic        g_mem_valid, g_mem_write;
  logic [63:0] g_mem_addr, g_mem_wdata, g_mem_rdata = '0;
  logic [7:0]  g_mem_wstrb;
  logic        g_mem_rvalid = 1'b0, g_mem_fault = 1'b0;
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

  always @(posedge clk) begin
    g_mem_rvalid <= 1'b0;
    g_mem_fault  <= 1'b0;
    if (!reset && g_mem_valid) begin
      if ((g_mem_addr >> 3) >= WORDS) g_mem_fault <= 1'b1;
      else if (g_mem_write) gmem[g_mem_addr >> 3] <= g_mem_wdata;
      else begin g_mem_rvalid <= 1'b1; g_mem_rdata <= gmem[g_mem_addr >> 3]; end
    end
  end

  logic        g_err_r [MAXOPS], g_bit_r [MAXOPS];
  logic [55:0] g_val_r [MAXOPS];

  `include "gold_ops.svh"
  `include "range_stim.svh"

  task automatic run_gold();
    logic e, b;
    logic [55:0] v;
    for (int n = 0; n < ops; n++) begin
      if (s_op[n] < 4'd8) begin
        gold_op(64'd0, s_bit[n], s_op[n][2:0], e, b);
        v = '0;
      end else
        gold_range(s_op[n], s_bit[n], s_len[n], s_src[n], s_fn[n], s_dry[n], e, b, v);
      g_err_r[n] = e; g_bit_r[n] = b; g_val_r[n] = v;
    end
  endtask

  // ------------------------------------------------------------ DUT
  logic         in_valid = 1'b0, in_ready;
  logic [127:0] in_data = '0;
  logic         out_valid, out_ready = 1'b0;
  logic [127:0] out_data;
  logic [$clog2(WORDS)-1:0] host_word = '0;
  logic [63:0]  host_wdata = '0, host_rdata;
  logic         host_write_stb = 1'b0, host_read_stb = 1'b0, host_rdata_valid, host_busy;
  logic         idle;
  logic [31:0]  ops_accepted, results_sent;

  bitacc_pcie_core #(.LANES(LANES), .WORDS_PER_LANE(WPL)) dut (.*);

  // result sink: random backpressure plus a long stall every 1500 cycles
  logic [63:0] r_res [MAXOPS];
  integer nres = 0, sink_cyc = 0;
  always @(negedge clk) begin
    sink_cyc <= sink_cyc + 1;
    out_ready <= ((sink_cyc % 1500) >= 300) && (rnd(3) != 0);
  end
  always @(posedge clk) begin
    if (!reset && out_valid && out_ready) begin
      for (int i = 0; i < 2; i++) r_res[nres + i] <= out_data[64*i +: 64];
      nres <= nres + 2;
    end
  end

  // Watchdog: fail fast instead of hanging if results stop arriving.
  // Armed only while the stream runs; any new result beat resets it.
  integer stall = 0, last_nres = 0;
  bit streaming = 0;
  always @(posedge clk) begin
    if (!reset) begin
      if (!streaming || nres != last_nres) stall <= 0; else stall <= stall + 1;
      last_nres <= nres;
      if (stall > 20000) $fatal(1, "core stalled: no result beat for 20000 cycles");
    end
  end

  task automatic run_stream();
    integer n = 0;
    streaming = 1;
    while (n < ops) begin
      @(negedge clk);
      if (rnd(10) == 0) in_valid = 1'b0;
      else begin
        in_valid = 1'b1;
        in_data = {s_src[n], s_len[n], s_fn[n], s_dry[n], s_op[n], s_bit[n]};
        if (in_ready) n++;                                           // in_ready is stable until the edge
      end
    end
    @(negedge clk); in_valid = 1'b0;
    while (nres < ops) @(negedge clk);
    streaming = 0;
  endtask

  task automatic host_write(input integer w, input logic [63:0] v);
    @(negedge clk);
    host_word = w; host_wdata = v; host_write_stb = 1'b1;
    @(negedge clk); host_write_stb = 1'b0;
    while (host_busy) @(negedge clk);
  endtask

  task automatic host_read(input integer w, output logic [63:0] v);
    integer waited = 0;
    @(negedge clk);
    host_word = w; host_read_stb = 1'b1;
    @(negedge clk); host_read_stb = 1'b0;
    while (!host_rdata_valid && waited < 100) begin @(negedge clk); waited++; end
    check(host_rdata_valid, $sformatf("host read of word %0d completes", w));
    v = host_rdata;
  endtask

  // ------------------------------------------------------------ main
  logic [63:0] v;
  integer kind, n_hot = 0, n_any = 0, n_past = 0, n_wrap = 0, n_undef = 0, n_range = 0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 3;
    if (!$value$plusargs("ops=%d", ops)) ops = 3200;
    ops = (ops / 2) * 2;
    seed0 = seed;
    for (int w = 0; w < WORDS; w++) begin init[w] = {rnd32(), rnd32()}; gmem[w] = init[w]; end
    for (int n = 0; n < ops; n++) begin
      kind = ((n % 24) < 16) ? 0 : 40 + rnd(60);
      s_op[n] = (rnd(12) == 0) ? 4'(5 + rnd(3)) : 4'(rnd(5));
      s_len[n] = '0; s_src[n] = '0; s_fn[n] = '0; s_dry[n] = 1'b0;
      if (s_op[n] > 4'd4) n_undef++;
      if (kind >= 40 && rnd(3) == 0) begin
        n_range++;
        gen_range(s_op[n], s_bit[n], s_len[n], s_src[n], s_fn[n], s_dry[n]);
      end else if (kind < 40) begin n_hot++;  s_bit[n] = 64'(rnd(4) * LANES) * 64 + rnd(64); end
      else if (kind < 80) begin n_any++; s_bit[n] = rnd(WORDS * 64); end
      else if (kind < 95) begin n_past++; s_bit[n] = WORDS * 64 + rnd(1024); end
      else begin n_wrap++; s_bit[n] = {rnd32(), rnd32()}; end
    end
    $display("stimulus: hot=%0d anywhere=%0d past_end=%0d wrap=%0d undefined_op=%0d range=%0d",
             n_hot, n_any, n_past, n_wrap, n_undef, n_range);

    repeat (3) @(negedge clk);
    reset = 1'b0;
    for (int w = 0; w < WORDS; w++) host_write(w, init[w]);
    for (int w = 0; w < WORDS; w++) begin
      host_read(w, v);
      check(v === init[w], $sformatf("host read back word %0d", w));
    end

    fork
      run_gold();
      run_stream();
    join

    for (int n = 0; n < ops; n++) begin
      check(r_res[n][7:2] == 6'b101000, $sformatf("result %0d tag %h", n, r_res[n]));
      check(r_res[n][1] === g_err_r[n],
            $sformatf("result %0d (op %0d, a %h, len %0d): error %b, reference %b",
                      n, s_op[n], s_bit[n], s_len[n], r_res[n][1], g_err_r[n]));
      if (!g_err_r[n])
        check(r_res[n][0] === g_bit_r[n] && r_res[n][63:8] === g_val_r[n],
              $sformatf("result %0d (op %0d, a %h, len %0d, src %0d, fn %0d): bit %b value %0d, reference %b %0d",
                        n, s_op[n], s_bit[n], s_len[n], s_src[n], s_fn[n],
                        r_res[n][0], r_res[n][63:8], g_bit_r[n], g_val_r[n]));
      else
        check(r_res[n][0] === 1'b0 && r_res[n][63:8] === '0, $sformatf("result %0d: error has bit 0, value 0", n));
      range_cover(s_op[n], s_bit[n], s_len[n], s_src[n], s_fn[n], s_dry[n], g_err_r[n], g_bit_r[n]);
    end
    range_cover_check();
    repeat (5) @(negedge clk);
    check(idle, "core idle after the stream");
    check(ops_accepted == ops, $sformatf("ops_accepted %0d", ops_accepted));
    check(results_sent == ops, $sformatf("results_sent %0d", results_sent));
    for (int w = 0; w < WORDS; w++) begin
      host_read(w, v);
      check(v === gmem[w], $sformatf("final word %0d: %h, reference %h", w, v, gmem[w]));
    end

    $display("checks=%0d fails=%0d lanes=%0d words=%0d ops=%0d seed=%0d", checks, fails, LANES, WORDS, ops, seed0);
    if (fails != 0) $fatal(1, "FAIL");
    $display("PASS: PCIe core matches the reference core");
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "global timeout");
  end
endmodule
