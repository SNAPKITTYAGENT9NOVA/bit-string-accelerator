// Random range-operation stimulus and coverage, shared by tb_engine and
// tb_pcie_core. Included after gold_ops.svh in a module that provides WORDS,
// LANES, rnd(n), rnd32() and check(cond, what).
//
// Classes: every range opcode and the undefined opcode 15; bit ranges that are
// short (word-crossing), multi-step, empty, at the end of the store, past the
// end and 64-bit wrapping; BULK regions that are disjoint, identical,
// overlapping (error), out of range, with every function, undefined functions
// and dry runs; FIND over a region the last fill emptied (not found) or past it.
// Coverage is counted from what was executed (operation and reference result),
// not from the generator's intent.

logic [63:0] rs_fill_a = '0;
logic [31:0] rs_fill_len = '0;
logic [3:0]  rs_fill_op = '0;

function automatic logic [63:0] rs_min(input logic [63:0] x, input logic [63:0] y);
  rs_min = x < y ? x : y;
endfunction

task automatic gen_range(output logic [3:0] op, output logic [63:0] a, output logic [31:0] len,
                         output logic [23:0] src, output logic [2:0] fn, output logic dry);
  integer c, lc, pc, tries;
  logic [63:0] bits, dst, l;
  bits = 64'(WORDS) * 64;
  src = '0; fn = '0; dry = 1'b0; len = '0; a = '0; op = R_COUNT;
  c = rnd(100);
  if (c < 4) begin                                   // undefined opcode
    op = 4'd15; a = rnd(WORDS * 64); len = rnd(64);
  end else if (c < 14 && rs_fill_len != 0 && rs_fill_op != R_FLIPR) begin
    // FIND the value the last fill removed: not found in the region, maybe found past it
    op  = rs_fill_op == R_SETR ? R_FIND0 : R_FIND1;
    a   = rs_fill_a;
    len = 32'(rs_min(64'(rs_fill_len) + (rnd(2) == 0 ? 0 : rnd(130)), bits - rs_fill_a));
  end else if (c < 60) begin                         // bit range
    op = 4'(8 + rnd(6));
    lc = rnd(100);
    if (lc < 45)      len = rnd(130);
    else if (lc < 88) len = rnd(64 * rs_min(WORDS, 3 * LANES + 3) + 1);
    else              len = 0;
    pc = rnd(100);
    if (pc < 82)      a = rnd(bits - len + 1);
    else if (pc < 86) a = bits - len;                // ends exactly at the end of the store
    else if (pc < 93) a = bits - len + 1 + rnd(64);  // past the end
    else if (pc < 97) a = {rnd32(), rnd32()};
    else              a = ~64'd0 - rnd(64);          // a + len wraps 64 bits
    if ((op == R_SETR || op == R_CLEARR || op == R_FLIPR) && len != 0
        && !range_error(op, a, len, src, fn)) begin
      rs_fill_a = a; rs_fill_len = len; rs_fill_op = op;
    end
  end else begin                                     // BULK
    op  = R_BULK;
    fn  = rnd(10) == 0 ? 3'(5 + rnd(3)) : 3'(rnd(5));
    dry = rnd(4) == 0;
    lc  = rnd(100);
    if (lc < 50)      l = rnd(3 * LANES + 3);
    else if (lc < 92) l = rnd(rs_min(WORDS / 2, 64) + 1);
    else              l = 0;
    len = 32'(l);
    src = 24'(rnd(WORDS - l + 1));
    pc  = rnd(100);
    if (pc < 60) begin                               // disjoint
      dst = rnd(WORDS - l + 1); tries = 0;
      while (tries < 50 && l != 0 && dst < 64'(src) + l && 64'(src) < dst + l) begin
        dst = rnd(WORDS - l + 1); tries++;
      end
    end else if (pc < 75) dst = 64'(src);            // identical
    else if (pc < 87) dst = 64'(src) + 1 + rnd(l > 1 ? l - 1 : 1);   // overlapping
    else if (pc < 95) dst = WORDS - l + 1 + rnd(8);  // past the end
    else              dst = {rnd32(), rnd32()};
    a = dst;
  end
endtask

integer cov_op [16];
integer cov_fn [8];
integer cov_dry = 0, cov_same = 0, cov_overlap = 0, cov_empty = 0, cov_rerr = 0, cov_whole = 0;
integer cov_multi_bits = 0, cov_multi_bulk = 0, cov_found = 0, cov_notfound = 0, cov_end = 0;
initial begin
  for (int i = 0; i < 16; i++) cov_op[i] = 0;
  for (int i = 0; i < 8; i++) cov_fn[i] = 0;
end

task automatic range_cover(input logic [3:0] op, input logic [63:0] a, input logic [31:0] len,
                           input logic [23:0] src, input logic [2:0] fn, input logic dry,
                           input logic err, input logic b);
  logic [64:0] e;
  e = {1'b0, a} + 65'(len);
  if (op < R_COUNT) begin
    // single-bit operation: not a range class
  end else if (err) begin
    cov_rerr++;
    if (op == R_BULK && fn <= 3'd4 && e <= 65'(WORDS) && 65'(src) + 65'(len) <= 65'(WORDS)) cov_overlap++;
  end else begin
    cov_op[op]++;
    if (len == 0) cov_empty++;
    if (op == R_BULK) begin
      cov_fn[fn]++;
      if (dry) cov_dry++;
      if (a == 64'(src) && len != 0) cov_same++;
      if (len > 2 * LANES) cov_multi_bulk++;
    end else begin
      if (len > 64 * 2 * LANES) cov_multi_bits++;
      if (len != 0 && e == 65'(WORDS) * 64) cov_end++;
      if (a == 0 && e == 65'(WORDS) * 64) cov_whole++;
      if ((op == R_FIND1 || op == R_FIND0) && len != 0) begin
        if (b) cov_found++; else cov_notfound++;
      end
    end
  end
endtask

task automatic range_cover_check();
  for (int op = 8; op <= 14; op++)
    check(cov_op[op] > 0, $sformatf("range opcode %0d executed without error", op));
  for (int f = 0; f <= 4; f++)
    check(cov_fn[f] > 0, $sformatf("BULK function %0d executed", f));
  check(cov_dry > 0, "BULK dry run executed");
  check(cov_same > 0, "BULK with identical regions executed");
  check(cov_overlap > 0, "BULK with overlapping regions rejected");
  check(cov_empty > 0, "empty range executed");
  check(cov_multi_bits > 0 && cov_multi_bulk > 0, "multi-step bit range and BULK executed");
  check(cov_end > 0, "bit range ending at the end of the store executed");
  check(cov_found > 0 && cov_notfound > 0, "FIND found and not found");
  check(cov_rerr > 0, "invalid range operations rejected");
  $display("range coverage: count=%0d find1=%0d find0=%0d setr=%0d clearr=%0d flipr=%0d bulk=%0d (copy %0d and %0d or %0d xor %0d andn %0d dry %0d same %0d) overlap_err=%0d errors=%0d empty=%0d whole=%0d found=%0d not_found=%0d",
           cov_op[8], cov_op[9], cov_op[10], cov_op[11], cov_op[12], cov_op[13], cov_op[14],
           cov_fn[0], cov_fn[1], cov_fn[2], cov_fn[3], cov_fn[4], cov_dry, cov_same,
           cov_overlap, cov_rerr, cov_empty, cov_whole, cov_found, cov_notfound);
endtask
