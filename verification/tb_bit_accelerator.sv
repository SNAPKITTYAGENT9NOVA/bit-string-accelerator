// Self-checking testbench for rtl/bit_accelerator.sv.
//
// A memory slave with randomized backpressure, read latency and fault injection
// drives the DUT. Every accepted operation is checked against a reference model:
//   - mem_addr of every request equals ((base<<3)+offset)>>6<<3 (64-bit wrap)
//   - write data equals the expected modified word, with all byte strobes set
//   - GET/TEST/illegal opcodes never write
//   - exactly one result_valid pulse per operation, with error and result_bit
//     valid in that same cycle
//   - op_ready is low from acceptance until the result pulse
//   - reset cancels an in-flight operation: no result, no write after reset
// Directed cases run first, then a seeded random phase (+seed=N, +ops=N).
`timescale 1ns/1ps
module tb_bit_accelerator;
  localparam int DEPTH = 64;          // memory words, indexed by mem_addr[8:3]
  localparam int TIMEOUT = 200;       // cycles before an operation is declared hung

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic op_valid = 1'b0, op_ready;
  logic [63:0] base_address = '0, bit_offset = '0;
  logic [2:0] operation = '0;
  logic result_valid, result_bit, error;
  logic mem_valid, mem_write;
  logic [63:0] mem_addr, mem_wdata;
  logic [7:0] mem_wstrb;
  logic mem_ready = 1'b0, mem_rvalid = 1'b0, mem_fault = 1'b0;
  logic [63:0] mem_rdata = '0;

  bit_accelerator dut (.*);

  always #5 clk = ~clk;

  // ---------------------------------------------------------------- memory slave
  logic [63:0] mem [0:DEPTH-1];
  integer seed = 1;
  integer ready_pct = 100;            // probability (%) that mem_ready is high
  integer max_lat = 0;                // read response latency, 0..max_lat extra cycles
  bit fault_read_next = 1'b0;         // fault the next accepted read
  bit fault_write_next = 1'b0;        // fault the next accepted write
  bit rd_pending = 1'b0, rd_fault = 1'b0;
  integer rd_delay = 0;
  logic [63:0] rd_addr = '0;
  integer writes_seen = 0;

  function automatic integer rnd(input integer n);  // 0..n-1
    rnd = (n <= 1) ? 0 : ($unsigned($random(seed)) % n);
  endfunction

  always @(posedge clk) begin
    mem_rvalid <= 1'b0;
    mem_fault  <= 1'b0;
    mem_ready  <= (rnd(100) < ready_pct);
    if (reset) begin
      rd_pending <= 1'b0;
    end else begin
      if (mem_valid && mem_ready && !mem_write) begin
        rd_pending <= 1'b1;
        rd_delay   <= rnd(max_lat + 1);
        rd_addr    <= mem_addr;
        rd_fault   <= fault_read_next;
        fault_read_next <= 1'b0;
      end
      if (rd_pending) begin
        if (rd_delay == 0) begin
          rd_pending <= 1'b0;
          if (rd_fault) mem_fault <= 1'b1;
          else begin
            mem_rvalid <= 1'b1;
            mem_rdata  <= mem[rd_addr[8:3]];
          end
        end else rd_delay <= rd_delay - 1;
      end
      if (mem_valid && mem_ready && mem_write) begin
        writes_seen <= writes_seen + 1;
        if (fault_write_next) begin
          mem_fault <= 1'b1;          // seen by the DUT in WRITE_WAIT
          fault_write_next <= 1'b0;
        end else begin
          mem[mem_addr[8:3]] <= mem_wdata;
        end
      end
    end
  end

  // -------------------------------------------------------------- bookkeeping
  integer checks = 0, fails = 0;
  task automatic check(input bit cond, input string what);
    checks++;
    if (!cond) begin
      fails++;
      $display("FAIL @%0t: %s", $time, what);
    end
  endtask

  // Request-level checks against the operation currently in flight.
  bit in_flight = 1'b0;
  logic [63:0] exp_addr;
  logic [63:0] exp_wdata;
  bit exp_write;
  integer results_seen = 0;

  always @(posedge clk) begin
    if (!reset) begin
      if (mem_valid) begin
        check(in_flight, "memory request while no operation is in flight");
        check(mem_addr === exp_addr,
              $sformatf("mem_addr %h, expected %h", mem_addr, exp_addr));
        if (mem_write) begin
          check(exp_write, "write issued for an operation that must not write");
          check(mem_wstrb === 8'hFF, $sformatf("mem_wstrb %h, expected ff", mem_wstrb));
          check(mem_wdata === exp_wdata,
                $sformatf("mem_wdata %h, expected %h", mem_wdata, exp_wdata));
        end
      end
      if (in_flight && !result_valid) check(!op_ready, "op_ready high while busy");
      if (result_valid) results_seen <= results_seen + 1;
    end
  end

  // ------------------------------------------------------------- reference model
  function automatic logic [63:0] eff_bit(input logic [63:0] b, input logic [63:0] o);
    eff_bit = (b << 3) + o;
  endfunction

  // Run one operation and check its result. fault_rd / fault_wr inject a fault on
  // the read or write of this operation. Returns when result_valid has been seen.
  task automatic run_op(input logic [63:0] b, input logic [63:0] o, input logic [2:0] op,
                        input bit fault_rd, input bit fault_wr);
    logic [63:0] eb, word, onehot;
    logic [5:0] idx;
    bit exp_bit, exp_err, writes;
    integer waited, w0;
    eb = eff_bit(b, o);
    idx = eb[5:0];
    onehot = 64'd1 << idx;
    word = mem[(eb >> 6) % DEPTH];
    writes = (op == 3'b010 || op == 3'b011 || op == 3'b100);
    exp_err = fault_rd || (!fault_rd && op > 3'b100) || (writes && fault_wr);
    case (op)
      3'b010: begin exp_wdata = word | onehot;  exp_bit = 1'b1; end
      3'b011: begin exp_wdata = word & ~onehot; exp_bit = 1'b0; end
      3'b100: begin exp_wdata = word ^ onehot;  exp_bit = !word[idx]; end
      default: begin exp_wdata = word;          exp_bit = word[idx]; end
    endcase
    exp_addr  = (eb >> 6) << 3;
    exp_write = writes && !fault_rd;

    @(negedge clk);
    fault_read_next  = fault_rd;
    fault_write_next = fault_wr;
    base_address = b; bit_offset = o; operation = op; op_valid = 1'b1;
    waited = 0;
    while (!op_ready) begin @(negedge clk); waited++; end
    @(posedge clk); w0 = writes_seen;      // accepted on this edge
    @(negedge clk); op_valid = 1'b0; in_flight = 1'b1;
    base_address = '1; bit_offset = '1; operation = 3'b111;  // must be ignored now
    waited = 0;
    while (!result_valid && waited < TIMEOUT) begin @(negedge clk); waited++; end
    check(result_valid, $sformatf("timeout: op %0d base %h off %h", op, b, o));
    if (result_valid) begin
      check(error === exp_err,
            $sformatf("op %0d base %h off %h: error %b, expected %b (sampled with result_valid)",
                      op, b, o, error, exp_err));
      if (!exp_err)
        check(result_bit === exp_bit,
              $sformatf("op %0d base %h off %h: result_bit %b, expected %b",
                        op, b, o, result_bit, exp_bit));
      check(writes_seen - w0 == (exp_write ? 1 : 0),
            $sformatf("op %0d: %0d writes, expected %0d", op, writes_seen - w0, exp_write));
      if (exp_write && !fault_wr)
        check(mem[(eb >> 6) % DEPTH] === exp_wdata, "memory word not updated as expected");
      if (!exp_write || fault_wr)
        check(mem[(eb >> 6) % DEPTH] === word, "memory word changed by a non-writing op");
    end
    @(negedge clk);
    check(!result_valid, "result_valid longer than one cycle");
    in_flight = 1'b0;
  endtask

  // Start an operation and assert reset `after` cycles into it.
  task automatic reset_during_op(input logic [2:0] op, input integer after);
    integer w0, r0;
    logic [63:0] snapshot [0:DEPTH-1];
    for (int k = 0; k < DEPTH; k++) snapshot[k] = mem[k];
    exp_addr = 64'd0; exp_wdata = mem[0] ^ 64'd1; exp_write = (op >= 3'b010 && op <= 3'b100);
    if (op == 3'b010) exp_wdata = mem[0] | 64'd1;
    if (op == 3'b011) exp_wdata = mem[0] & ~64'd1;
    @(negedge clk);
    base_address = 0; bit_offset = 0; operation = op; op_valid = 1'b1;
    while (!op_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk); op_valid = 1'b0; in_flight = 1'b1;
    repeat (after) @(negedge clk);
    if (result_valid) begin
      in_flight = 1'b0;               // finished before the reset point; nothing to cancel
    end else begin
      reset = 1'b1;
      @(negedge clk);
      w0 = writes_seen; r0 = results_seen;
      reset = 1'b0; in_flight = 1'b0;
      // Restore memory so a write committed before reset does not affect later checks.
      for (int k = 0; k < DEPTH; k++) mem[k] = snapshot[k];
      repeat (10) @(negedge clk);
      check(results_seen == r0, $sformatf("result_valid after reset cancelled op %0d", op));
      check(writes_seen == w0, $sformatf("write after reset cancelled op %0d", op));
      check(op_ready, "DUT not idle after reset");
    end
  endtask

  // --------------------------------------------------------------------- stimulus
  integer ops = 2000;
  integer seed0;
  logic [63:0] rb, ro;
  logic [2:0] rop;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("ops=%d", ops)) ops = 2000;
    seed0 = seed;
    for (int k = 0; k < DEPTH; k++) mem[k] = '0;
    mem[0] = 64'h8000_0000_0000_0001;
    mem[1] = 64'h0000_0000_0000_0040;
    repeat (3) @(negedge clk);
    reset = 1'b0;

    // Directed: the original eight cases (base 0, ideal memory).
    run_op(0, 0,  3'b000, 0, 0);  // GET  word0 bit0  -> 1
    run_op(0, 63, 3'b000, 0, 0);  // GET  word0 bit63 -> 1
    run_op(0, 64, 3'b000, 0, 0);  // GET  word1 bit0  -> 0
    run_op(0, 7,  3'b001, 0, 0);  // TEST word0 bit7  -> 0
    run_op(0, 1,  3'b010, 0, 0);  // SET
    run_op(0, 1,  3'b001, 0, 0);  // TEST -> 1
    run_op(0, 1,  3'b011, 0, 0);  // CLEAR
    run_op(0, 1,  3'b100, 0, 0);  // TOGGLE

    // Directed: non-zero base (byte address), word crossing, high/wrapping addresses.
    run_op(8, 6, 3'b000, 0, 0);                         // byte 8 = word 1, bit 6 -> 1
    run_op(7, 7, 3'b010, 0, 0);                         // bit 63 of word 0 via base 7
    run_op(7, 8, 3'b100, 0, 0);                         // crosses into word 1
    run_op(64'h1FFF_FFFF_FFFF_FFFF, 64'd8, 3'b000, 0, 0); // (base<<3)+8 wraps to 0
    run_op(64'hFFFF_FFFF_FFFF_FFF8, 0, 3'b000, 0, 0);   // base<<3 drops top 3 bits
    run_op(0, 64'hFFFF_FFFF_FFFF_FFFF, 3'b010, 0, 0);   // last bit of address space

    // Directed: illegal opcodes report error and never write.
    run_op(0, 3, 3'b101, 0, 0);
    run_op(0, 3, 3'b110, 0, 0);
    run_op(0, 3, 3'b111, 0, 0);

    // Directed: faults. A read fault aborts before any write; a write fault
    // reports error on the same cycle as result_valid.
    run_op(0, 5, 3'b000, 1, 0);
    run_op(0, 5, 3'b010, 1, 0);
    run_op(0, 5, 3'b010, 0, 1);
    run_op(0, 5, 3'b011, 0, 1);
    run_op(0, 5, 3'b100, 0, 1);
    run_op(0, 5, 3'b000, 0, 0);   // a clean op right after faults has error=0

    // Directed: reset at every point of a read-modify-write and of a read.
    for (int a = 0; a < 8; a++) reset_during_op(3'b100, a);
    for (int a = 0; a < 4; a++) reset_during_op(3'b000, a);

    // Random: backpressure, variable read latency, faults, all opcodes.
    ready_pct = 60; max_lat = 3;
    for (int n = 0; n < ops; n++) begin
      rb  = {$random(seed), $random(seed)};
      ro  = {$random(seed), $random(seed)};
      if (rnd(2) == 0) begin rb = rnd(64); ro = rnd(1024); end  // dense region
      rop = rnd(8);
      if (rnd(10) == 0) rop = 3'b101 + rnd(3);
      else rop = rnd(5);
      run_op(rb, ro, rop, rnd(20) == 0, rnd(20) == 0);
    end

    $display("checks=%0d fails=%0d seed=%0d ops=%0d", checks, fails, seed0, ops);
    if (fails == 0) $display("PASS: bit accelerator tests");
    else $fatal(1, "FAIL: %0d of %0d checks failed", fails, checks);
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "global timeout");
  end
endmodule
