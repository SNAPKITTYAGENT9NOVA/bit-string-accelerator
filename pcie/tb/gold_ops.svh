// Reference semantics of every engine operation, executed on the single-op
// reference core rtl/bit_accelerator.sv.
//
// Included inside a testbench module that provides: clk; the reference core's
// inputs g_op_valid, g_base, g_off, g_opc and outputs g_op_ready, g_res_valid,
// g_res_bit, g_error; WORDS (bit-store size in 64-bit words); and
// task check(cond, what).
//
// Range operations are defined as sequences of single-bit operations on the
// reference core, bit by bit in ascending order:
//   COUNT          GET every bit, add them up
//   FIND1/FIND0    GET bits until one equals 1/0
//   SETR/CLEARR/FLIPR  GET each bit (counted), then SET/CLEAR/TOGGLE it
//   BULK           per bit: GET src, GET dst, compute, SET/CLEAR dst if it changes
// Which range operations are errors is a specification choice (range_error);
// for bit ranges it is cross-checked against the reference core, which must
// reject the last bit of every invalid non-empty range.

localparam logic [2:0] G_GET = 3'd0, G_SET = 3'd2, G_CLEAR = 3'd3, G_TOGGLE = 3'd4;
localparam logic [3:0] R_COUNT = 4'd8, R_FIND1 = 4'd9, R_FIND0 = 4'd10,
                       R_SETR = 4'd11, R_CLEARR = 4'd12, R_FLIPR = 4'd13, R_BULK = 4'd14;

integer gold_ops_issued = 0;

// One operation on the reference core.
task automatic gold_op(input logic [63:0] base, input logic [63:0] off, input logic [2:0] op,
                       output logic err, output logic b);
  @(negedge clk);
  g_base = base; g_off = off; g_opc = op; g_op_valid = 1'b1;
  while (!g_op_ready) @(negedge clk);
  @(negedge clk); g_op_valid = 1'b0;
  while (!g_res_valid) @(negedge clk);
  err = g_error;
  b   = g_res_bit;
  gold_ops_issued++;
endtask

// GET/SET/CLEAR/TOGGLE at an absolute bit address that must be valid.
task automatic gold_bit(input logic [63:0] bitaddr, input logic [2:0] op, output logic b);
  logic err;
  gold_op(64'd0, bitaddr, op, err, b);
  if (err) check(1'b0, $sformatf("reference core accepts bit %h inside a valid range", bitaddr));
endtask

function automatic logic range_error(input logic [3:0] op, input logic [63:0] a, input logic [31:0] len,
                                     input logic [23:0] src, input logic [2:0] fn);
  logic [64:0] e, se, words;
  e = {1'b0, a} + 65'(len);
  se = 65'(src) + 65'(len);
  words = 65'(WORDS);
  if (op >= R_COUNT && op <= R_FLIPR) range_error = e > (words << 6);
  else if (op == R_BULK)
    range_error = fn > 3'd4 || e > words || se > words
                  || (len != 0 && {1'b0, a} != 65'(src) && {1'b0, a} < se && 65'(src) < e);
  else range_error = 1'b1;
endfunction

function automatic logic bulk_fn(input logic [2:0] fn, input logic d, input logic s);
  case (fn)
    3'd0:    bulk_fn = s;
    3'd1:    bulk_fn = d & s;
    3'd2:    bulk_fn = d | s;
    3'd3:    bulk_fn = d ^ s;
    default: bulk_fn = d & !s;
  endcase
endfunction

// A range operation (opcode 8-15) on the reference core.
task automatic gold_range(input logic [3:0] op, input logic [63:0] a, input logic [31:0] len,
                          input logic [23:0] src, input logic [2:0] fn, input logic dry,
                          output logic err, output logic b, output logic [55:0] val);
  logic x, y, r, e, done;
  logic [64:0] last;
  logic [63:0] k, bitaddr, sbit;
  err = range_error(op, a, len, src, fn);
  b = 1'b0;
  val = '0;
  if (err) begin
    last = {1'b0, a} + 65'(len) - 65'd1;
    if (op >= R_COUNT && op <= R_FLIPR && len != 0 && !last[64]) begin
      gold_op(64'd0, last[63:0], G_GET, e, x);
      check(e, $sformatf("reference core rejects the last bit %h of invalid range op %0d", last[63:0], op));
    end
  end else if (op == R_COUNT) begin
    for (k = 0; k < 64'(len); k++) begin
      gold_bit(a + k, G_GET, x);
      val = val + 56'(x);
    end
  end else if (op == R_FIND1 || op == R_FIND0) begin
    k = 0; done = 1'b0;
    while (!done && k < 64'(len)) begin
      gold_bit(a + k, G_GET, x);
      if (x == (op == R_FIND1)) begin done = 1'b1; b = 1'b1; val = 56'(a + k); end
      k++;
    end
  end else if (op == R_SETR || op == R_CLEARR || op == R_FLIPR) begin
    for (k = 0; k < 64'(len); k++) begin
      gold_bit(a + k, G_GET, x);
      val = val + 56'(x);
      gold_bit(a + k, op == R_SETR ? G_SET : op == R_CLEARR ? G_CLEAR : G_TOGGLE, y);
    end
  end else begin                                   // BULK: a = dst word
    for (k = 0; k < 64'(len) * 64; k++) begin
      bitaddr = (a << 6) + k;
      sbit    = (64'(src) << 6) + k;
      gold_bit(sbit, G_GET, x);
      gold_bit(bitaddr, G_GET, y);
      r = bulk_fn(fn, y, x);
      val = val + 56'(r);
      if (!dry && r != y) gold_bit(bitaddr, r ? G_SET : G_CLEAR, y);
    end
  end
  if (!err && op != R_FIND1 && op != R_FIND0) b = val != 0;
endtask
