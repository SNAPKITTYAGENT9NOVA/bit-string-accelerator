// bitacc_pcie_core (128-bit descriptor/result streams + register interface)
// against the single-op reference core rtl/bit_accelerator.sv.
//
// The reference executes each descriptor as base = 0, offset = bit address.
// The stream side sees input gaps and output backpressure with long stalls.
// Every result byte, the counters, the idle flag and the final memory (read
// through the register interface) must match. Exits non-zero on any mismatch.
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
  function automatic integer rnd(input integer n);
    rnd = (n <= 1) ? 0 : ($unsigned($random(seed)) % n);
  endfunction

  // ------------------------------------------------------------ stimulus
  logic [2:0]  s_op  [MAXOPS];
  logic [63:0] s_bit [MAXOPS];
  logic [63:0] init  [WORDS];

  // ------------------------------------------------------------ reference
  logic        g_op_valid = 1'b0, g_op_ready;
  logic [63:0] g_off = '0;
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
    .base_address(64'd0), .bit_offset(g_off), .operation(g_opc),
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

  logic g_err_r [MAXOPS], g_bit_r [MAXOPS];
  task automatic run_gold();
    for (int n = 0; n < ops; n++) begin
      @(negedge clk);
      g_off = s_bit[n]; g_opc = s_op[n]; g_op_valid = 1'b1;
      while (!g_op_ready) @(negedge clk);
      @(negedge clk); g_op_valid = 1'b0;
      while (!g_res_valid) @(negedge clk);
      g_err_r[n] = g_error; g_bit_r[n] = g_res_bit;
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
  logic [7:0] r_byte [MAXOPS];
  integer nres = 0, sink_cyc = 0;
  always @(negedge clk) begin
    sink_cyc <= sink_cyc + 1;
    out_ready <= ((sink_cyc % 1500) >= 300) && (rnd(3) != 0);
  end
  always @(posedge clk) begin
    if (!reset && out_valid && out_ready) begin
      for (int i = 0; i < 16; i++) r_byte[nres + i] <= out_data[8*i +: 8];
      nres <= nres + 16;
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
        in_data = {61'h1abcdef0123456 ^ 61'(n), s_op[n], s_bit[n]};  // reserved bits must be ignored
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
  integer kind, n_hot = 0, n_any = 0, n_past = 0, n_wrap = 0, n_undef = 0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 3;
    if (!$value$plusargs("ops=%d", ops)) ops = 3200;
    ops = (ops / 16) * 16;
    seed0 = seed;
    for (int w = 0; w < WORDS; w++) begin init[w] = {$random(seed), $random(seed)}; gmem[w] = init[w]; end
    for (int n = 0; n < ops; n++) begin
      kind = ((n % 24) < 16) ? 0 : 40 + rnd(60);
      s_op[n] = (rnd(12) == 0) ? 3'(5 + rnd(3)) : 3'(rnd(5));
      if (s_op[n] > 3'd4) n_undef++;
      if (kind < 40) begin n_hot++;  s_bit[n] = 64'(rnd(4) * LANES) * 64 + rnd(64); end
      else if (kind < 80) begin n_any++; s_bit[n] = rnd(WORDS * 64); end
      else if (kind < 95) begin n_past++; s_bit[n] = WORDS * 64 + rnd(1024); end
      else begin n_wrap++; s_bit[n] = {$random(seed), $random(seed)}; end
    end
    $display("stimulus: hot=%0d anywhere=%0d past_end=%0d wrap=%0d undefined_op=%0d",
             n_hot, n_any, n_past, n_wrap, n_undef);

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
      check(r_byte[n][7:2] == 6'b101000, $sformatf("result %0d tag %h", n, r_byte[n]));
      check(r_byte[n][1] === g_err_r[n],
            $sformatf("result %0d (op %0d, bit %h): error %b, reference %b",
                      n, s_op[n], s_bit[n], r_byte[n][1], g_err_r[n]));
      if (!g_err_r[n])
        check(r_byte[n][0] === g_bit_r[n],
              $sformatf("result %0d (op %0d, bit %h): bit %b, reference %b",
                        n, s_op[n], s_bit[n], r_byte[n][0], g_bit_r[n]));
    end
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
