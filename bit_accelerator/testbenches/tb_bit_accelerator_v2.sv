// Cycle-accurate testbench for bit_accelerator_v2.
// Inputs are driven on negedge; every posedge logs the pre-edge value of each
// signal, so log[c] is exactly what the DUT/memory saw during cycle c.
// Spec (1-cycle-latency memory): accept@a, READ_REQ@a+1, READ_RESP@a+2, RESULT_VALID@a+3.

module tb_bit_accelerator_v2;

  localparam int MAXC = 4096;

  logic clk = 1'b0;
  logic reset;
  logic        op_valid, op_ready;
  logic [63:0] base_address, bit_offset;
  logic [2:0]  operation;
  logic        result_valid, result_bit, error;
  logic        mem_valid, mem_write, mem_ready;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0]  mem_wstrb;
  logic        mem_rvalid, mem_fault;

  bit_accelerator_v2 dut (.*);

  always #5 clk = ~clk;

  // ---------------- memory model (1-cycle read latency) ----------------
  logic [63:0] memory [0:1023];
  bit stall_en;
  int stall_lo, stall_hi;
  int cyc = 0;

  assign mem_ready = !(stall_en && cyc >= stall_lo && cyc <= stall_hi);
  assign mem_fault = 1'b0;

  always_ff @(posedge clk) begin
    mem_rvalid <= 1'b0;
    if (mem_valid && mem_ready) begin
      if (mem_write) begin
        for (int i = 0; i < 8; i++)
          if (mem_wstrb[i]) memory[mem_addr[12:3]][i*8 +: 8] <= mem_wdata[i*8 +: 8];
      end else begin
        mem_rvalid <= 1'b1;
        mem_rdata  <= memory[mem_addr[12:3]];
      end
    end
  end

  // ---------------- per-cycle log ----------------
  logic        l_opv [0:MAXC-1], l_opr [0:MAXC-1];
  logic        l_mv  [0:MAXC-1], l_mw  [0:MAXC-1], l_mr [0:MAXC-1];
  logic        l_rv  [0:MAXC-1], l_res [0:MAXC-1], l_bit [0:MAXC-1];
  logic [63:0] l_wd  [0:MAXC-1];

  always @(posedge clk) begin
    l_opv[cyc] = op_valid;  l_opr[cyc] = op_ready;
    l_mv[cyc]  = mem_valid; l_mw[cyc]  = mem_write; l_mr[cyc] = mem_ready;
    l_rv[cyc]  = mem_rvalid; l_res[cyc] = result_valid; l_bit[cyc] = result_bit;
    l_wd[cyc]  = mem_wdata;
    cyc <= cyc + 1;
  end

  // ---------------- checking helpers ----------------
  int fails = 0, checks = 0;

  task automatic check(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      fails++;
      $display("  FAIL: %s", msg);
    end
  endtask

  task automatic init_mem();
    for (int i = 0; i < 1024; i++) memory[i] = {32'hA5A50000 | i[15:0], 32'h0000F00D | (i[15:0] << 16)};
    memory[0] = 64'h0000_0000_0000_0020;  // bit 5 set only
    memory[1] = 64'h0000_0000_0000_0000;
  endtask

  task automatic do_reset();
    @(negedge clk);
    reset = 1'b1; op_valid = 1'b0;
    @(negedge clk);
    reset = 1'b0;
    @(negedge clk);
  endtask

  // Issue one op; returns the cycle index at which it was accepted.
  task automatic issue(input logic [2:0] op, input logic [63:0] base, input logic [63:0] off,
                       output int acc);
    @(negedge clk);
    op_valid = 1'b1; operation = op; base_address = base; bit_offset = off;
    acc = cyc;                       // op_valid/op_ready are sampled at the next posedge, cycle == cyc
    @(negedge clk);
    op_valid = 1'b0;
  endtask

  task automatic wait_cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

  function automatic int count_results(input int lo, input int hi);
    int n = 0;
    for (int c = lo; c <= hi; c++) if (l_res[c]) n++;
    return n;
  endfunction

  // ---------------- tests ----------------
  task automatic t_get(input string name, input logic [63:0] base, input logic [63:0] off, input bit exp_bit);
    int a;
    $display("TEST %s", name);
    do_reset();
    issue(3'b000, base, off, a);
    wait_cycles(10);
    check(l_opv[a] && l_opr[a],                 "op accepted at a");
    check(l_mv[a+1] && !l_mw[a+1],              "READ_REQUEST at a+1");
    check(!l_mv[a+2],                           "no second request at a+2");
    check(l_rv[a+2],                            "READ_RESPONSE at a+2");
    check(l_res[a+3],                           "RESULT_VALID at a+3");
    check(l_bit[a+3] == exp_bit,                "result_bit value");
    check(!l_res[a+4],                          "result_valid is one-cycle (low at a+4)");
    check(count_results(a, a+10) == 1,          "exactly one result pulse");
    check(l_opr[a+4] && !l_opr[a+1] && !l_opr[a+3], "op_ready low while busy, high after result");
  endtask

  task automatic t_modify(input string name, input logic [2:0] op, input logic [63:0] base,
                          input logic [63:0] off, input logic [63:0] exp_word);
    int a;
    logic [63:0] widx;
    widx = ((base << 3) + off) >> 6;
    $display("TEST %s", name);
    do_reset();
    issue(op, base, off, a);
    wait_cycles(12);
    check(l_mv[a+1] && !l_mw[a+1],              "READ_REQUEST at a+1");
    check(l_rv[a+2],                            "READ_RESPONSE at a+2");
    check(!l_mv[a+3],                           "MODIFY: no mem request at a+3");
    check(l_mv[a+4] && l_mw[a+4] && l_mr[a+4],  "WRITE accepted (valid&&write&&ready) at a+4");
    check(!l_mv[a+5],                           "no request after accepted write at a+5");
    check(l_res[a+6],                           "RESULT_VALID at a+6");
    check(count_results(a, a+12) == 1,          "exactly one result pulse");
    check(memory[widx[9:0]] == exp_word,        "memory word after RMW");
  endtask

  task automatic t_write_stall();
    int a;
    logic [63:0] mem0_pre;
    $display("TEST write stall (mem_ready low a+4..a+6)");
    do_reset();
    mem0_pre = memory[0];
    @(negedge clk);
    stall_en = 1'b1; stall_lo = cyc + 1 + 4; stall_hi = cyc + 1 + 6;   // issue() accepts at cyc+1
    issue(3'b010, 64'd0, 64'd0, a);
    check(a + 4 == stall_lo, "stall window aligned to write request");
    wait_cycles(14);
    stall_en = 1'b0;
    check(l_mv[a+4] && l_mw[a+4] && !l_mr[a+4], "write request held, not accepted a+4");
    check(l_mv[a+5] && l_mw[a+5] && !l_mr[a+5], "write request held a+5");
    check(l_mv[a+6] && l_mw[a+6] && !l_mr[a+6], "write request held a+6");
    check(l_wd[a+4] == l_wd[a+5] && l_wd[a+5] == l_wd[a+6], "wdata stable during stall");
    check(l_mv[a+7] && l_mw[a+7] && l_mr[a+7],  "write accepted at a+7");
    check(!l_mv[a+8],                           "no request after accept");
    check(count_results(a, a+7) == 0,           "no result mem0_pre write accepted");
    check(l_res[a+9],                           "RESULT_VALID at a+9 (2 cycles after accept)");
    check(count_results(a, a+14) == 1,          "exactly one result pulse");
    check(memory[0] == (mem0_pre | 64'h1),        "write committed once");
  endtask

  task automatic t_read_stall();
    int a;
    $display("TEST read stall (mem_ready low a+1..a+2)");
    do_reset();
    @(negedge clk);
    stall_en = 1'b1; stall_lo = cyc + 1 + 1; stall_hi = cyc + 1 + 2;
    issue(3'b000, 64'd0, 64'd5, a);
    wait_cycles(10);
    stall_en = 1'b0;
    check(l_mv[a+1] && !l_mr[a+1] && l_mv[a+2] && !l_mr[a+2], "read request held during stall");
    check(l_mv[a+3] && l_mr[a+3],               "read accepted at a+3");
    check(l_rv[a+4],                            "read response at a+4");
    check(l_res[a+5] && l_bit[a+5],             "RESULT_VALID at a+5 with bit=1");
    check(count_results(a, a+10) == 1,          "exactly one result pulse");
  endtask

  // Reset asserted for one cycle at cycle (a + k): operation must be cancelled.
  task automatic t_reset_at(input int k, input string where);
    int a;
    logic [63:0] mem0_pre;
    $display("TEST reset cancels op during %s (reset@a+%0d)", where, k);
    do_reset();
    mem0_pre = memory[0];
    issue(3'b010, 64'd0, 64'd0, a);
    while (cyc < a + k) @(negedge clk);
    reset = 1'b1;
    @(negedge clk);
    reset = 1'b0;
    wait_cycles(12);
    check(count_results(a, a+16) == 0,          "no result_valid for cancelled op");
    check(!mem_valid && !result_valid,          "idle outputs after reset");
    check(op_ready,                             "op_ready after reset");
    if (k <= 4)
      check(memory[0] == mem0_pre,                "no write committed (cancelled before write accepted)");
    // a fresh op must work normally afterwards
    begin
      int b;
      issue(3'b000, 64'd0, 64'd5, b);
      wait_cycles(8);
      check(l_res[b+3] && l_bit[b+3],           "fresh op after reset completes normally");
    end
  endtask

  initial begin
    reset = 1'b1; op_valid = 1'b0; operation = '0; base_address = '0; bit_offset = '0;
    stall_en = 1'b0; stall_lo = 0; stall_hi = 0;
    init_mem();

    t_get("GET bit5 (set)",           64'd0, 64'd5,  1'b1);
    t_get("GET bit4 (clear)",         64'd0, 64'd4,  1'b0);
    t_get("GET word1 bit 0 via off=64",   64'd0, 64'd64, 1'b0);

    t_modify("SET bit0",    3'b010, 64'd0, 64'd0,  64'h21);
    init_mem();
    t_modify("CLEAR bit5",  3'b011, 64'd0, 64'd5,  64'h00);
    init_mem();
    t_modify("TOGGLE bit5", 3'b100, 64'd0, 64'd5,  64'h00);
    init_mem();
    t_modify("SET cross-word (off=70 -> word1 bit6)", 3'b010, 64'd0, 64'd70, 64'h40);
    init_mem();
    t_modify("SET base=8 off=3 -> word1 bit3",        3'b010, 64'd8, 64'd3,  64'h08);
    init_mem();

    t_write_stall();
    init_mem();
    t_read_stall();
    init_mem();

    t_reset_at(1, "READ_REQUEST");
    init_mem();
    t_reset_at(2, "READ_WAIT");
    init_mem();
    t_reset_at(3, "MODIFY");
    init_mem();
    t_reset_at(4, "WRITE_REQUEST");
    init_mem();
    t_reset_at(5, "WRITE_WAIT");

    $display("\nchecks=%0d fails=%0d", checks, fails);
    if (fails == 0) $display("ALL PASS"); else $display("FAILED");
    $finish;
  end

  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
