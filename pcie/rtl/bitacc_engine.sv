// Parallel bit-operation engine.
//
// A stream of operation descriptors is executed by LANES lanes, each owning
// one bank of the bit store. Word w lives in lane w % LANES at local address
// w / LANES. Results leave in descriptor order through a reorder buffer, and
// equal those of executing the stream one operation at a time (checked against
// the reference core rtl/bit_accelerator.sv by pcie/tb/tb_engine.sv).
//
// Single-bit operations (op 0-4, as in the reference core):
//   effective bit a = (base << 3) + offset               (mod 2^64)
//   word = a >> 6, bit index = a[5:0]
//   error = word >= WORDS                                 (no write)
//   0 GET, 1 TEST: bit;  2 SET, 3 CLEAR, 4 TOGGLE: write, return the new bit
// All operations on one word run in one lane, in arrival order. Operations on
// different words commute, so lanes can complete out of order.
//
// Range operations (op 8-15). Each is a barrier: it starts when every earlier
// operation has completed, runs on all lanes at once, and later operations
// start after it. The bit store is therefore always in the state that
// sequential execution gives.
//   bit ranges, bits [a, a + len):
//    8 COUNT   value = number of set bits
//    9 FIND1   value = index of the first set bit;   bit = found
//   10 FIND0   value = index of the first clear bit; bit = found
//   11 SETR, 12 CLEARR, 13 FLIPR: set/clear/invert every bit;
//             value = number of set bits before the operation
//   15 MATCH  pattern = word src, mask = word src+1. Position s in [a, a+len)
//             matches if every mask bit j has s + j < a + len and
//             bit(s + j) == pattern[j]. fn 0: value = number of matches;
//             fn 1: value = first matching position, bit = found.
//             Needs WITH_MATCH = 1; otherwise opcode 15 is an error.
//   error = a + len > WORDS * 64; MATCH also: fn > 1 || src + 2 > WORDS
//   word regions, words dst = a .. a+len-1 and src = src .. src+len-1:
//   14 BULK   dst[k] = fn(dst[k], src[k]) for every k, unless dry;
//             fn 0 COPY, 1 AND, 2 OR, 3 XOR, 4 ANDN (dst & ~src);
//             value = number of set bits in the results
//   error = fn > 4 || dst + len > WORDS || src + len > WORDS
//           || the regions overlap without being identical  (no write)
// For range operations without a find result, bit = (value != 0). len = 0
// is valid (value 0, not found). Undefined opcodes (5-7) are errors. An
// error result has bit = 0 and value = 0.
//
// A range operation processes LANES words per step. Bit ranges step through
// groups of LANES consecutive words (one per lane, same local address). BULK
// pairs dst[k] with src[k], which may live in different lanes: lane i reads
// src element k = j*LANES + ((i - src) mod LANES) at local address
// j + (src + ((i - src) mod LANES)) / LANES, and dst lane m receives it from
// lane (m - delta) mod LANES, delta = (dst - src) mod LANES. formal/lane_map.mlw
// proves these index identities. Each BULK step is a src read, a dst read and
// a write: LANES words per 2 cycles. MATCH steps like a bit range; lane i
// checks the 64 positions of the word before its own (word w - 1), with the
// window {word w, word w - 1}; lane 0 takes word w - 1 from the last lane of
// the previous step. With MATCH_LANES < LANES, each group of LANES words is
// matched in LANES / MATCH_LANES sub-steps (the group is read again in each;
// MATCH does not write): unit u takes word sub * MATCH_LANES + u. That is
// MATCH_LANES * 64 positions per cycle.
//
// Timing: every block-RAM port is driven by a register (through the port
// mux), the descriptor's 64-bit sums are registered before they are compared,
// and popcount, lowest-set-bit and the cross-lane sums are balanced trees.
// Range pipeline: S0 issue -> S1 address register (bank read) -> S2 data
// (rdata, masks registered) -> S3 compute from registered data (write and
// result word registered) -> S4 write, popcount -> S5 reduce.
//
// The host port reads and writes whole words while the engine is idle
// (host_ready is low while any operation is in flight).
module bitacc_engine #(
  parameter int LANES          = 4,     // power of two, >= 2
  parameter int WORDS_PER_LANE = 512,   // power of two, >= 2
  parameter int ROB_DEPTH      = 32,    // power of two; max operations in flight
  parameter int FIFO_DEPTH     = 16,    // per-lane queue; power of two
  parameter bit WITH_MATCH     = 1'b1,  // MATCH unit
  parameter int MATCH_LANES    = LANES  // matcher units (power of two, 1 .. LANES; ~4,000 LUTs each on XC7)
)(
  input  logic        clk,
  input  logic        reset,

  // descriptors in
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [3:0]  cmd_op,
  input  logic [63:0] cmd_base,
  input  logic [63:0] cmd_offset,
  input  logic [31:0] cmd_len,          // range length: bits, or words for BULK
  input  logic [23:0] cmd_src,          // BULK source word, MATCH pattern word
  input  logic [2:0]  cmd_fn,           // BULK function, MATCH result kind
  input  logic        cmd_dry,          // BULK: count only, no write

  // results out, in descriptor order
  output logic        res_valid,
  input  logic        res_ready,
  output logic        res_error,
  output logic        res_bit,
  output logic [55:0] res_value,

  // host word access (only while idle)
  input  logic        host_valid,
  output logic        host_ready,
  input  logic        host_write,
  input  logic [$clog2(LANES*WORDS_PER_LANE)-1:0] host_word,
  input  logic [63:0] host_wdata,
  output logic        host_rvalid,
  output logic [63:0] host_rdata,

  output logic        idle
);
  localparam int LW = $clog2(LANES);
  localparam int AW = $clog2(WORDS_PER_LANE);
  localparam int GW = AW + 1;                    // step counter (MATCH reads one step past the end)
  localparam int WW = LW + AW;                   // global word index width
  localparam int BW = WW + 6;                    // global bit index width
  localparam int CW = BW + 1;                    // bit count width (0 .. WORDS*64)
  localparam int SW = $clog2(ROB_DEPTH);
  localparam int FW = $clog2(FIFO_DEPTH);
  localparam int MK  = LANES / MATCH_LANES;      // MATCH sub-steps per group
  localparam int SBW = MK > 1 ? $clog2(MK) : 1;

  localparam logic [3:0] OP_SET = 4'd2, OP_CLEAR = 4'd3, OP_TOGGLE = 4'd4;
  localparam logic [3:0] OP_COUNT = 4'd8, OP_FIND1 = 4'd9, OP_FIND0 = 4'd10,
                         OP_SETR = 4'd11, OP_CLEARR = 4'd12, OP_FLIPR = 4'd13,
                         OP_BULK = 4'd14, OP_MATCH = 4'd15;
  localparam logic [2:0] FN_COPY = 3'd0, FN_AND = 3'd1, FN_OR = 3'd2, FN_XOR = 3'd3, FN_ANDN = 3'd4;

  localparam logic [64:0] STORE_WORDS = 65'(LANES * WORDS_PER_LANE);
  localparam logic [64:0] STORE_BITS  = STORE_WORDS << 6;

  // Balanced trees (a loop that accumulates bit by bit synthesizes a 64-deep chain).
  function automatic logic [6:0] popcount64(input logic [63:0] x);
    logic [6:0] s [64];
    for (int i = 0; i < 64; i++) s[i] = 7'(x[i]);
    for (int w = 32; w >= 1; w = w / 2)
      for (int i = 0; i < w; i++) s[i] = s[2*i] + s[2*i+1];
    popcount64 = s[0];
  endfunction

  function automatic logic [5:0] ctz64(input logic [63:0] x);  // index of the lowest set bit
    logic [7:0] any;
    logic [2:0] pos [8];
    logic [2:0] grp;
    for (int k = 0; k < 8; k++) begin
      any[k] = |x[8*k +: 8];
      pos[k] = '0;
      for (int b = 7; b >= 0; b--) if (x[8*k + b]) pos[k] = 3'(b);
    end
    grp = '0;
    for (int k = 7; k >= 0; k--) if (any[k]) grp = 3'(k);
    ctz64 = {grp, pos[grp]};
  endfunction

  function automatic logic [5:0] msb64(input logic [63:0] x);  // index of the highest set bit (0 if none)
    logic [7:0] any;
    logic [2:0] pos [8];
    logic [2:0] grp;
    for (int k = 0; k < 8; k++) begin
      any[k] = |x[8*k +: 8];
      pos[k] = '0;
      for (int b = 0; b < 8; b++) if (x[8*k + b]) pos[k] = 3'(b);
    end
    grp = '0;
    for (int k = 0; k < 8; k++) if (any[k]) grp = 3'(k);
    msb64 = {grp, pos[grp]};
  endfunction

  // ---------------------------------------------------------------- stage P: accept
  // A 2-entry skid buffer: cmd_ready is a register (computed from next-state
  // counts), so no combinational path runs from the dispatch logic back to the
  // descriptor source. The 64-bit sums are registered here and compared in D.
  logic          p_valid, p_take;
  logic [1:0]    p_cnt;               // entries held (0..2); entry 0 is the head
  logic          p_rdy;
  logic [SW-1:0] pe_seq  [2];
  logic [3:0]    pe_op   [2];
  logic [2:0]    pe_fn   [2];
  logic          pe_dry  [2];
  logic [63:0]   pe_eff  [2];
  logic [31:0]   pe_len  [2];
  logic [23:0]   pe_src  [2];
  logic [64:0]   pe_end  [2];         // a + len: bit range end, or dst region end
  logic [32:0]   pe_send [2];         // src + len: src region end

  logic [SW:0]   inflight;            // descriptors accepted and not yet emitted
  logic [SW:0]   inflight_next;
  logic [SW-1:0] next_seq;
  logic          d_valid, d_take;
  logic          accept, emit;
  logic [1:0]    p_cnt_next;
  logic          p_wp, p_rp;          // write and read slots of the circular 2-entry buffer

  logic [63:0]   c_eff;               // effective bit address, mod 2^64
  assign c_eff     = (cmd_base << 3) + cmd_offset;
  assign cmd_ready = p_rdy;
  assign accept    = cmd_valid && p_rdy;
  assign p_valid   = p_cnt != 2'd0;
  assign p_take    = p_valid && (!d_valid || d_take);
  assign p_cnt_next    = p_cnt + 2'(accept) - 2'(p_take);
  // inflight counts the descriptors held in stages P and D too.
  assign inflight_next = inflight + (SW+1)'(accept) - (SW+1)'(emit);

  // the head entry, as stage D sees it (taking it only moves p_rp, so the
  // dispatch decision drives no wide enable here)
  logic [SW-1:0] p_seq;
  logic [3:0]    p_op;
  logic [2:0]    p_fn;
  logic          p_dry;
  logic [63:0]   p_eff;
  logic [31:0]   p_len;
  logic [23:0]   p_src;
  logic [64:0]   p_end;
  logic [32:0]   p_send;
  assign p_seq = pe_seq[p_rp]; assign p_op = pe_op[p_rp]; assign p_fn = pe_fn[p_rp]; assign p_dry = pe_dry[p_rp];
  assign p_eff = pe_eff[p_rp]; assign p_len = pe_len[p_rp]; assign p_src = pe_src[p_rp];
  assign p_end = pe_end[p_rp]; assign p_send = pe_send[p_rp];

  always_ff @(posedge clk) begin
    if (reset) begin
      p_cnt <= '0; p_rdy <= 1'b0; next_seq <= '0; p_wp <= 1'b0; p_rp <= 1'b0;
      for (int i = 0; i < 2; i++) begin
        pe_seq[i] <= '0; pe_op[i] <= '0; pe_fn[i] <= '0; pe_dry[i] <= 1'b0; pe_eff[i] <= '0;
        pe_len[i] <= '0; pe_src[i] <= '0; pe_end[i] <= '0; pe_send[i] <= '0;
      end
    end else begin
      p_cnt <= p_cnt_next;
      p_rdy <= p_cnt_next < 2'd2 && inflight_next < (SW+1)'(ROB_DEPTH);
      if (p_take) p_rp <= !p_rp;
      if (accept) begin
        pe_seq[p_wp]  <= next_seq;
        pe_op[p_wp]   <= cmd_op;
        pe_fn[p_wp]   <= cmd_fn;
        pe_dry[p_wp]  <= cmd_dry;
        pe_eff[p_wp]  <= c_eff;
        pe_len[p_wp]  <= cmd_len;
        pe_src[p_wp]  <= cmd_src;
        pe_end[p_wp]  <= {1'b0, c_eff} + 65'(cmd_len);
        pe_send[p_wp] <= 33'(cmd_src) + 33'(cmd_len);
        p_wp          <= !p_wp;
        next_seq      <= next_seq + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- stage D: decode
  logic [64:0]   a_x, src_x, send_x;
  logic          c_range, c_err;
  assign a_x    = {1'b0, p_eff};
  assign src_x  = 65'(p_src);
  assign send_x = 65'(p_send);
  assign c_range = p_op >= OP_COUNT;
  always_comb begin
    if (p_op <= OP_TOGGLE)      c_err = (p_eff >> (WW + 6)) != '0;
    else if (p_op < OP_COUNT)   c_err = 1'b1;                    // 5-7
    else if (p_op < OP_BULK)    c_err = p_end > STORE_BITS;
    else if (p_op == OP_BULK)   c_err = p_fn > FN_ANDN || p_end > STORE_WORDS || send_x > STORE_WORDS
                                        || (p_len != '0 && a_x != src_x && a_x < send_x && src_x < p_end);
    else                        c_err = !WITH_MATCH || p_fn > 3'd1 || p_end > STORE_BITS
                                        || src_x + 65'd2 > STORE_WORDS;
  end

  logic [SW-1:0] d_seq;
  logic          d_err, d_range;
  logic [3:0]    d_op;
  logic [LW-1:0] d_lane;
  logic [AW-1:0] d_local;
  logic [5:0]    d_bit;
  logic [2:0]    d_fn;
  logic          d_dry, d_empty;
  logic [BW-1:0] d_lo, d_hi;          // first and last bit (bit ranges); d_lo[WW-1:0] = dst (BULK)
  logic [WW-1:0] d_src;
  logic [WW:0]   d_n;                 // BULK word count (<= WORDS when valid)

  always_ff @(posedge clk) begin
    if (reset) begin
      d_valid <= 1'b0;
      d_seq <= '0; d_err <= 1'b0; d_range <= 1'b0; d_op <= '0; d_lane <= '0; d_local <= '0; d_bit <= '0;
      d_fn <= '0; d_dry <= 1'b0; d_empty <= 1'b0; d_lo <= '0; d_hi <= '0; d_src <= '0; d_n <= '0;
    end else begin
      if (d_take) d_valid <= 1'b0;
      if (p_take) begin
        d_valid  <= 1'b1;
        d_seq    <= p_seq;
        d_err    <= c_err;
        d_range  <= c_range;
        d_op     <= p_op;
        d_lane   <= p_eff[6 +: LW];
        d_local  <= p_eff[6 + LW +: AW];
        d_bit    <= p_eff[5:0];
        d_fn     <= p_fn;
        d_dry    <= p_dry;
        d_empty  <= p_len == '0;
        d_lo     <= p_eff[BW-1:0];
        d_hi     <= BW'(p_end - 65'd1);
        d_src    <= src_x[WW-1:0];
        d_n      <= (WW+1)'(p_len);
      end
    end
  end

  // ---------------------------------------------------------------- dispatch
  logic [LANES-1:0] q_full, q_empty;
  logic [LANES-1:0] q_push, q_pop;
  logic [SW-1:0]    q_seq   [LANES];
  logic [AW-1:0]    q_local [LANES];
  logic [5:0]       q_bit   [LANES];
  logic [2:0]       q_op    [LANES];
  logic [LANES-1:0] l_busy;
  logic             r_busy, r_start;
  logic [SW:0]      ops_out;          // single-bit operations dispatched and not completed
  logic [LANES-1:0] l_done;

  // Errors bypass the lanes and go straight to the reorder buffer. A range
  // operation waits until every dispatched single-bit operation has completed
  // (ops_out is a register; it reaches 0 the cycle after the last completion
  // pulse, after that operation's write); nothing dispatches while it runs.
  assign r_start = d_valid && !d_err && d_range && !r_busy && ops_out == '0;
  assign d_take  = d_valid && (d_err || r_start || (!d_range && !r_busy && !q_full[d_lane]));
  always_comb begin
    q_push = '0;
    if (d_valid && !d_err && !d_range && !r_busy && !q_full[d_lane]) q_push[d_lane] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (reset) ops_out <= '0;
    else begin
      logic [SW:0] done_n;
      done_n = '0;
      for (int i = 0; i < LANES; i++) done_n = done_n + (SW+1)'(l_done[i]);
      ops_out <= ops_out + (SW+1)'(|q_push) - done_n;
    end
  end

  // ---------------------------------------------------------------- range unit: control
  // R_IDLE -> R_INIT (derived constants from registered parameters) -> R_ISSUE
  // -> R_DRAIN -> R_IDLE; MATCH loads its pattern first:
  // R_INIT -> R_PAT -> R_PWAIT -> R_PSET1 -> R_PSET2 -> R_PSET3 -> R_ISSUE.
  typedef enum logic [3:0] {R_IDLE, R_INIT, R_PAT, R_PWAIT, R_PSET1, R_PSET2, R_PSET3,
                            R_ISSUE, R_DRAIN} rstate_t;
  localparam logic [2:0] K_BITS = 3'd0, K_SRC = 3'd1, K_DST = 3'd2, K_PAT = 3'd3, K_MAT = 3'd4;

  rstate_t       r_state;
  logic [SW-1:0] r_seq;
  logic [3:0]    r_op;
  logic [2:0]    r_fn;
  logic          r_dry, r_empty;
  logic [BW-1:0] r_lo, r_hi;          // first and last bit; MATCH: first and last position
  logic [WW-1:0] r_src;
  logic [WW:0]   r_n;
  logic [GW-1:0] r_g, r_glast;        // step: group (bit ranges, MATCH) or j (BULK)
  logic [SBW-1:0] r_sub;              // MATCH sub-step within the group
  logic          r_phase;             // BULK: 0 src read, 1 dst read
  logic [63:0]   r_lowm, r_highm;     // bit masks of the first and last word of the range
  logic [CW-1:0] r_acc;
  logic          r_found;
  logic [BW-1:0] r_idx;
  logic          r_done;
  logic          r_find, r_bulk, r_match;
  logic [63:0]   r_pat, r_msk;        // MATCH pattern and mask
  logic [LW-1:0] r_pat_lane, r_msk_lane;
  logic [5:0]    m_top;               // MATCH: highest mask bit (0 if the mask is 0)
  logic          m_neg;               // MATCH: last position below 0

  assign r_busy  = r_state != R_IDLE;
  assign r_bulk  = r_op == OP_BULK;
  assign r_match = r_op == OP_MATCH;
  assign r_find  = r_op == OP_FIND1 || r_op == OP_FIND0 || (r_match && r_fn[0]);

  // S0 issue: one read per lane per cycle
  logic          s0_valid;
  logic [2:0]    s0_kind;
  assign s0_valid = r_state == R_PAT || (r_state == R_ISSUE && !(r_find && r_found));
  always_comb begin
    if (r_state == R_PAT) s0_kind = K_PAT;
    else if (r_bulk)      s0_kind = r_phase ? K_DST : K_SRC;
    else if (r_match)     s0_kind = K_MAT;
    else                  s0_kind = K_BITS;
  end

  // central pipeline registers
  logic          s1_valid, s2_valid, s3_valid, s4_valid, s5_valid, s6_valid;
  logic [2:0]    s1_kind, s2_kind, s3_kind;
  logic [GW-1:0] s1_g, s2_g, s3_g, s4_g, s5_g;
  logic [SBW-1:0] s1_sub, s2_sub, s3_sub, s4_sub, s5_sub;
  logic [6:0]    s5_cnt [LANES];
  logic [LANES-1:0] s5_hit;
  logic [5:0]    s5_pos [LANES];

  // S5 reduce across lanes, registered into S6
  logic [LW+6:0] s5_sum, s6_sum;      // set bits (or matches) in this step, all lanes
  logic          s5_any, s6_any;
  logic [LW-1:0] s5_first;            // lowest lane with a hit
  logic [WW:0]   s5_word;             // word of that lane's result bits
  logic [BW-1:0] s6_idx;              // first hit of this step
  always_comb begin
    logic [LW+6:0] t [LANES];
    for (int i = 0; i < LANES; i++) t[i] = (LW+7)'(s5_cnt[i]);
    for (int lvl = 0; lvl < LW; lvl++)
      for (int i = 0; i < LANES / 2; i++)
        if (i < (LANES >> (lvl + 1))) t[i] = t[2*i] + t[2*i+1];
    s5_sum = t[0];
    s5_any = 1'b0; s5_first = '0;
    for (int i = LANES - 1; i >= 0; i--) if (s5_hit[i]) begin s5_any = 1'b1; s5_first = LW'(i); end
    // MATCH results of unit i belong to word g * LANES + sub * MATCH_LANES + i - 1
    if (r_match)
      s5_word = (WW+1)'({s5_g, LW'(0)}) + (WW+1)'(s5_sub) * (WW+1)'(MATCH_LANES)
                + (WW+1)'(s5_first) - (WW+1)'(1);
    else
      s5_word = {s5_g, s5_first};
  end

  always_ff @(posedge clk) begin
    r_done <= 1'b0;
    if (reset) begin
      r_state <= R_IDLE; r_seq <= '0; r_op <= '0; r_fn <= '0; r_dry <= 1'b0; r_empty <= 1'b0;
      r_lo <= '0; r_hi <= '0; r_src <= '0; r_n <= '0; r_g <= '0; r_glast <= '0;
      r_phase <= 1'b0; r_lowm <= '0; r_highm <= '0; r_acc <= '0; r_found <= 1'b0; r_idx <= '0;
      r_sub <= '0;
      s1_sub <= '0; s2_sub <= '0; s3_sub <= '0; s4_sub <= '0; s5_sub <= '0;
      r_pat_lane <= '0; r_msk_lane <= '0; m_top <= '0; m_neg <= 1'b0;
      s1_valid <= 1'b0; s1_kind <= K_BITS; s1_g <= '0;
      s2_valid <= 1'b0; s2_kind <= K_BITS; s2_g <= '0;
      s3_valid <= 1'b0; s3_kind <= K_BITS; s3_g <= '0;
      s4_valid <= 1'b0; s4_g <= '0; s5_valid <= 1'b0; s5_g <= '0;
      s6_valid <= 1'b0; s6_sum <= '0; s6_any <= 1'b0; s6_idx <= '0;
    end else begin
      case (r_state)
        R_IDLE: begin
          // follow the decode register while idle, so starting needs no wide enable
          r_seq <= d_seq; r_op <= d_op; r_fn <= d_fn; r_dry <= d_dry; r_empty <= d_empty;
          r_lo  <= d_lo;  r_hi <= d_hi; r_src <= d_src; r_n <= d_n;
          if (r_start) r_state <= R_INIT;
        end
        R_INIT: begin
          r_g     <= r_bulk ? '0 : GW'(r_lo[BW-1:6+LW]);
          r_glast <= r_bulk ? GW'((r_n - 1'b1) >> LW) : GW'(r_hi[BW-1:6+LW]);
          r_lowm  <= ~64'd0 << r_lo[5:0];
          r_highm <= ~64'd0 >> (6'd63 - r_hi[5:0]);
          r_pat_lane <= r_src[LW-1:0];
          r_msk_lane <= r_src[LW-1:0] + 1'b1;
          r_phase <= 1'b0; r_sub <= '0;
          r_acc   <= '0; r_found <= 1'b0; r_idx <= '0;
          r_state <= r_empty ? R_DRAIN : (r_match ? R_PAT : R_ISSUE);
        end
        R_PAT:   r_state <= R_PWAIT;
        R_PWAIT: if (!s1_valid && !s2_valid && !s3_valid) r_state <= R_PSET1;   // pattern captured
        R_PSET1: begin
          m_top   <= r_msk == '0 ? 6'd0 : msb64(r_msk);
          r_state <= R_PSET2;
        end
        R_PSET2: begin
          // positions [r_lo, r_hi - m_top]
          {m_neg, r_hi} <= {1'b0, r_hi} - (BW+1)'(m_top);
          r_state <= R_PSET3;
        end
        R_PSET3: begin
          // steps from the group of word r_lo to the group of word
          // (last position / 64) + 1, whose lane 0 computes the last word
          r_highm <= ~64'd0 >> (6'd63 - r_hi[5:0]);
          r_glast <= GW'(((WW+1)'(r_hi[BW-1:6]) + 1'b1) >> LW);
          r_state <= (m_neg || r_hi < r_lo) ? R_DRAIN : R_ISSUE;
        end
        R_ISSUE: begin
          if (r_bulk) begin
            r_phase <= !r_phase;
            if (r_phase) begin
              if (r_g == r_glast) r_state <= R_DRAIN;
              r_g <= r_g + 1'b1;
            end
          end else if (r_match && MK > 1) begin
            if (r_sub == SBW'(MK - 1)) begin
              if (r_g == r_glast || (r_find && r_found)) r_state <= R_DRAIN;
              r_g   <= r_g + 1'b1;
              r_sub <= '0;
            end else begin
              if (r_find && r_found) r_state <= R_DRAIN;
              r_sub <= r_sub + 1'b1;
            end
          end else begin
            if (r_g == r_glast || (r_find && r_found)) r_state <= R_DRAIN;
            r_g <= r_g + 1'b1;
          end
        end
        R_DRAIN: if (!s1_valid && !s2_valid && !s3_valid && !s4_valid && !s5_valid && !s6_valid) begin
          r_state <= R_IDLE;
          r_done  <= 1'b1;
        end
        default: r_state <= R_IDLE;
      endcase

      s1_valid <= s0_valid; s1_kind <= s0_kind; s1_g <= r_g;  s1_sub <= r_sub;
      s2_valid <= s1_valid; s2_kind <= s1_kind; s2_g <= s1_g; s2_sub <= s1_sub;
      s3_valid <= s2_valid; s3_kind <= s2_kind; s3_g <= s2_g; s3_sub <= s2_sub;
      s4_sub <= s3_sub; s5_sub <= s4_sub;
      s4_valid <= s3_valid && (s3_kind == K_BITS || s3_kind == K_DST || s3_kind == K_MAT);  s4_g <= s3_g;
      s5_valid <= s4_valid; s5_g <= s4_g;
      s6_valid <= s5_valid;
      s6_sum   <= s5_sum;
      s6_any   <= s5_any;
      s6_idx   <= {s5_word[WW-1:0], s5_pos[s5_first]};

      if (s6_valid) begin
        r_acc <= r_acc + CW'(s6_sum);
        if (r_find && !r_found && s6_any) begin
          r_found <= 1'b1;
          r_idx   <= s6_idx;
        end
      end
    end
  end

  // ---------------------------------------------------------------- lanes
  logic [SW-1:0]    l_seq [LANES];
  logic             l_bit [LANES];
  logic [63:0]      rq    [LANES];    // S3: registered bank data
  logic [63:0]      lane_rdata [LANES];

  // host access: global word -> lane, local address
  logic [LW-1:0] h_lane;
  logic [AW-1:0] h_local;
  assign h_lane  = host_word[LW-1:0];
  assign h_local = host_word[WW-1:LW];
  logic          h_pending;
  logic [LW-1:0] h_lane_q;

  // MATCH pattern capture (S3 of the K_PAT step)
  always_ff @(posedge clk) begin
    if (reset) begin
      r_pat <= '0; r_msk <= '0;
    end else begin
      if (WITH_MATCH && s3_valid && s3_kind == K_PAT) begin
        r_pat <= rq[r_pat_lane];
        r_msk <= rq[r_msk_lane];
      end
    end
  end

  genvar g;
  generate
    for (g = 0; g < LANES; g++) begin : lane
      // queue
      logic [SW+AW+6+3-1:0] fifo [FIFO_DEPTH];
      logic [FW:0] wp, rp;
      logic        full_q;              // registered from the next-state pointers
      assign q_full[g]  = full_q;
      assign q_empty[g] = (wp == rp);
      always_ff @(posedge clk) begin
        if (reset) begin
          wp <= '0; rp <= '0; full_q <= 1'b0;
        end else begin
          full_q <= ((wp + (FW+1)'(q_push[g])) - (rp + (FW+1)'(q_pop[g]))) == (FW+1)'(FIFO_DEPTH);
          if (q_push[g]) begin
            fifo[wp[FW-1:0]] <= {d_seq, d_local, d_bit, d_op[2:0]};
            wp <= wp + 1'b1;
          end
          if (q_pop[g]) rp <= rp + 1'b1;
        end
      end
      assign {q_seq[g], q_local[g], q_bit[g], q_op[g]} = fifo[rp[FW-1:0]];

      // bank: one write port, one synchronous read port (block RAM)
      logic [63:0]   bank [WORDS_PER_LANE];
      logic          we;
      logic [AW-1:0] raddr, waddr;
      logic [63:0]   wdata, rdata;
      always_ff @(posedge clk) begin
        if (we) bank[waddr] <= wdata;
        rdata <= bank[raddr];
      end

      // ---------------- single-bit execute: READ (address presented) -> MODIFY (data back, write)
      logic          st_mod;
      logic [SW-1:0] x_seq;
      logic [AW-1:0] x_local;
      logic [5:0]    x_bit;
      logic [2:0]    x_op;
      logic [63:0]   onehot, newword;
      logic          oldbit, newbit, writes;

      assign onehot = 64'd1 << x_bit;
      assign oldbit = rdata[x_bit];
      always_comb begin
        case ({1'b0, x_op})
          OP_SET:    begin newword = rdata | onehot;  newbit = 1'b1;    writes = 1'b1; end
          OP_CLEAR:  begin newword = rdata & ~onehot; newbit = 1'b0;    writes = 1'b1; end
          OP_TOGGLE: begin newword = rdata ^ onehot;  newbit = !oldbit; writes = 1'b1; end
          default:   begin newword = rdata;           newbit = oldbit;  writes = 1'b0; end
        endcase
      end

      assign q_pop[g]  = !q_empty[g] && !st_mod;
      assign l_busy[g] = st_mod || !q_empty[g];

      always_ff @(posedge clk) begin
        l_done[g] <= 1'b0;
        if (reset) begin
          st_mod <= 1'b0;
          x_seq <= '0; x_local <= '0; x_bit <= '0; x_op <= '0;
          l_seq[g] <= '0; l_bit[g] <= 1'b0;
        end else if (st_mod) begin
          st_mod   <= 1'b0;
          l_done[g] <= 1'b1;
          l_seq[g]  <= x_seq;
          l_bit[g]  <= newbit;
        end else if (q_pop[g]) begin
          st_mod  <= 1'b1;
          x_seq   <= q_seq[g];
          x_local <= q_local[g];
          x_bit   <= q_bit[g];
          x_op    <= q_op[g];
        end
      end

      // ---------------- range datapath
      // Per-operation constants (see the header): BULK dst element offset q
      // and the local base addresses of the src and dst regions; MATCH: the
      // local address of this lane's pattern-or-mask word.
      logic [LW-1:0] q_off, src_sel;
      logic [AW-1:0] sa, da, pa;
      always_ff @(posedge clk) begin
        if (reset) begin
          q_off <= '0; src_sel <= '0; sa <= '0; da <= '0; pa <= '0;
        end else if (r_state == R_INIT) begin
          q_off <= LW'(g) - r_lo[LW-1:0];
          // the src lane this dst lane takes its word from: (g - delta) mod LANES
          src_sel <= LW'(LW'(g) - LW'(r_lo[LW-1:0] - r_src[LW-1:0]));
          sa    <= AW'(((WW+1)'(r_src)    + (WW+1)'(LW'(LW'(g) - r_src[LW-1:0]))) >> LW);
          da    <= AW'(((WW+1)'(r_lo[WW-1:0]) + (WW+1)'(LW'(LW'(g) - r_lo[LW-1:0]))) >> LW);
          // word src (pattern) or src + 1 (mask), whichever lives in this lane
          pa    <= AW'(((WW+1)'(r_src) + (WW+1)'(LW'(g) != r_src[LW-1:0])) >> LW);
        end
      end

      // S1: registered read address
      logic [AW-1:0] s1_raddr;
      always_ff @(posedge clk) begin
        if (reset) s1_raddr <= '0;
        else case (s0_kind)
          K_SRC:   s1_raddr <= r_g[AW-1:0] + sa;
          K_DST:   s1_raddr <= r_g[AW-1:0] + da;
          K_PAT:   s1_raddr <= pa;
          default: s1_raddr <= r_g[AW-1:0];
        endcase
      end

      // S1 -> S2: where this lane's word lies in the range, from s1_g;
      // S2 -> S3: its bit mask. Also the BULK element bound and write addresses.
      logic [WW:0]   wv;                // word this lane's mask refers to
      logic [WW:0]   lo_w, hi_w;
      logic          s1_kvalid;
      // MATCH: unit g checks the positions of word g*LANES + sub*MATCH_LANES + g - 1
      assign wv        = (s1_kind == K_MAT)
                         ? (WW+1)'({s1_g, LW'(0)}) + (WW+1)'(s1_sub) * (WW+1)'(MATCH_LANES)
                           + (WW+1)'(g) - (WW+1)'(1)
                         : {s1_g, LW'(g)};
      assign lo_w      = (WW+1)'(r_lo[BW-1:6]);
      assign hi_w      = (WW+1)'(r_hi[BW-1:6]);
      assign s1_kvalid = ((WW+1)'({s1_g[AW-1:0], LW'(0)}) + (WW+1)'(q_off)) < r_n;

      logic          s2_in, s2_first, s2_last;
      logic [63:0]   s3_mask;
      logic          s2_kvalid, s3_kvalid;
      logic [AW-1:0] s2_waddr, s3_waddr;
      always_ff @(posedge clk) begin
        if (reset) begin
          s2_in <= 1'b0; s2_first <= 1'b0; s2_last <= 1'b0; s2_kvalid <= 1'b0; s2_waddr <= '0;
          s3_mask <= '0; s3_kvalid <= 1'b0; s3_waddr <= '0; rq[g] <= '0;
        end else begin
          s2_in     <= wv >= lo_w && wv <= hi_w;
          s2_first  <= wv == lo_w;
          s2_last   <= wv == hi_w;
          s2_kvalid <= s1_kvalid;
          s2_waddr  <= s1_kind == K_DST ? s1_g[AW-1:0] + da : s1_g[AW-1:0];
          s3_mask   <= s2_in ? ((s2_first ? r_lowm : ~64'd0) & (s2_last ? r_highm : ~64'd0)) : 64'd0;
          s3_kvalid <= s2_kvalid;
          s3_waddr  <= s2_waddr;
          rq[g]     <= rdata;               // S2 -> S3: bank data registered
        end
      end

      // Per-lane copies of the step's control (kept apart, so that no single
      // control net fans out to every lane's 64-bit muxes). l_op/l_fn/l_dry
      // follow r_op/r_fn/r_dry one cycle later, long before S3 uses them.
      (* keep *) logic [2:0] l3_kind;
      (* keep *) logic       l3_valid;
      (* keep *) logic [3:0] l_op;
      (* keep *) logic [2:0] l_fn;
      (* keep *) logic       l_dry;
      (* keep *) always_ff @(posedge clk) begin
        if (reset) begin
          l3_kind <= K_BITS; l3_valid <= 1'b0; l_op <= '0; l_fn <= '0; l_dry <= 1'b0;
        end else begin
          l3_kind <= s2_kind; l3_valid <= s2_valid; l_op <= r_op; l_fn <= r_fn; l_dry <= r_dry;
        end
      end

      // S3 compute, from registered data
      logic [63:0] src_q;               // BULK: this dst lane's src word of the current step
      logic [63:0] sel, fillword, srcw, bulkword, mvec;
      assign sel = (l_op == OP_FIND0 ? ~rq[g] : rq[g]) & s3_mask;
      always_comb begin
        case (l_op)
          OP_SETR:   fillword = rq[g] | s3_mask;
          OP_CLEARR: fillword = rq[g] & ~s3_mask;
          default:   fillword = rq[g] ^ s3_mask;     // FLIPR
        endcase
      end
      assign srcw = src_q;
      always_comb begin
        case (l_fn)
          FN_COPY: bulkword = srcw;
          FN_AND:  bulkword = rq[g] & srcw;
          FN_OR:   bulkword = rq[g] | srcw;
          FN_XOR:  bulkword = rq[g] ^ srcw;
          default: bulkword = rq[g] & ~srcw;      // ANDN
        endcase
      end
      if (WITH_MATCH && g < MATCH_LANES) begin : matcher
        // positions p of word w - 1: window bits p .. p+63 of {word w, word w - 1},
        // w = this sub-step's word idx of the group. Both are registered here at
        // S2. For idx 0, word w - 1 is the last lane's word of the previous
        // group (sub-steps issue on consecutive cycles), still in rq[LANES - 1].
        logic [LW-1:0] idx;
        logic [63:0]   m_hi, m_lo;
        logic [127:0]  win;
        // (s2_sub is 0 when MATCH_LANES == LANES, where LW'(MATCH_LANES) wraps to 0)
        assign idx = LW'(LW'(s2_sub) * LW'(MATCH_LANES) + LW'(g));
        always_ff @(posedge clk) begin
          if (reset) begin
            m_hi <= '0; m_lo <= '0;
          end else begin
            m_hi <= lane_rdata[idx];
            m_lo <= (idx == '0) ? rq[LANES-1] : lane_rdata[LW'(idx - 1'b1)];
          end
        end
        assign win = {m_hi, m_lo};
        // this unit's copy of the pattern and mask (loaded in R_PSET1, before any
        // MATCH step), so their bits do not fan out across all units
        (* keep *) logic [63:0] u_pat, u_msk;
        (* keep *) always_ff @(posedge clk) begin
          if (reset) begin
            u_pat <= '0; u_msk <= '0;
          end else if (r_state == R_PSET1) begin
            u_pat <= r_pat; u_msk <= r_msk;
          end
        end
        always_comb
          for (int p = 0; p < 64; p++) mvec[p] = ~|((win[p +: 64] ^ u_pat) & u_msk);
      end else begin : no_matcher
        assign mvec = '0;
      end

      // S3 -> S4: registered bank write and result word
      logic          w_we;
      logic [AW-1:0] w_waddr;
      logic [63:0]   w_wdata, s4_word;
      always_ff @(posedge clk) begin
        if (reset) begin
          w_we <= 1'b0; w_waddr <= '0; w_wdata <= '0; s4_word <= '0; src_q <= '0;
        end else begin
          w_we    <= 1'b0;
          w_waddr <= s3_waddr;
          // the cross-lane rotation ends in this register
          if (l3_valid && l3_kind == K_SRC) src_q <= rq[src_sel];
          case (l3_kind)
            K_DST: begin
              w_we    <= l3_valid && s3_kvalid && !l_dry;
              w_wdata <= bulkword;
              s4_word <= s3_kvalid ? bulkword : 64'd0;
            end
            K_MAT: s4_word <= (g < MATCH_LANES) ? (mvec & s3_mask) : 64'd0;
            default: begin
              w_we    <= l3_valid && l3_kind == K_BITS && s3_mask != '0
                         && (l_op == OP_SETR || l_op == OP_CLEARR || l_op == OP_FLIPR);
              w_wdata <= fillword;
              s4_word <= sel;
            end
          endcase
          if (s4_valid) begin
            s5_cnt[g] <= popcount64(s4_word);
            s5_hit[g] <= s4_word != '0;
            s5_pos[g] <= ctz64(s4_word);
          end
        end
      end

      // ---------------- bank port: range unit, else lane, else host (engine idle)
      logic [AW-1:0] q_addr;
      logic          q_idle;
      assign q_addr = q_local[g];
      assign q_idle = q_empty[g];
      always_comb begin
        raddr = q_addr; we = 1'b0; waddr = x_local; wdata = newword;
        if (r_busy) begin
          raddr = s1_raddr; we = w_we; waddr = w_waddr; wdata = w_wdata;
        end else if (st_mod) begin
          we = writes;
        end else if (q_idle && host_valid && host_ready && h_lane == LW'(g)) begin
          raddr = h_local; waddr = h_local; we = host_write; wdata = host_wdata;
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------- reorder buffer
  logic [ROB_DEPTH-1:0] rob_full, rob_err, rob_bit, rob_rng;
  logic [55:0]          rob_val [ROB_DEPTH];   // written only by the range unit
  logic [SW-1:0]        head;
  logic                 r_bitout;
  logic [55:0]          r_valout;

  assign r_bitout  = r_find ? r_found : (r_acc != '0);
  assign r_valout  = r_find ? (r_found ? 56'(r_idx) : 56'd0) : 56'(r_acc);

  assign res_valid = rob_full[head];
  assign res_error = rob_err[head];
  assign res_bit   = rob_bit[head];
  assign res_value = rob_rng[head] ? rob_val[head] : 56'd0;
  assign emit      = res_valid && res_ready;

  always_ff @(posedge clk) begin
    if (r_done) rob_val[r_seq] <= r_valout;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      rob_full <= '0; rob_err <= '0; rob_bit <= '0; rob_rng <= '0; head <= '0; inflight <= '0;
    end else begin
      if (emit) begin
        rob_full[head] <= 1'b0;
        head <= head + 1'b1;
      end
      if (d_take && d_err) begin
        rob_full[d_seq] <= 1'b1; rob_err[d_seq] <= 1'b1; rob_bit[d_seq] <= 1'b0; rob_rng[d_seq] <= 1'b0;
      end
      for (int i = 0; i < LANES; i++) begin
        if (l_done[i]) begin
          rob_full[l_seq[i]] <= 1'b1; rob_err[l_seq[i]] <= 1'b0; rob_bit[l_seq[i]] <= l_bit[i];
          rob_rng[l_seq[i]] <= 1'b0;
        end
      end
      if (r_done) begin
        rob_full[r_seq] <= 1'b1; rob_err[r_seq] <= 1'b0; rob_bit[r_seq] <= r_bitout; rob_rng[r_seq] <= 1'b1;
      end
      inflight <= inflight_next;
    end
  end

  // ---------------------------------------------------------------- host port
  assign idle       = (inflight == '0) && !p_valid && !d_valid && (l_busy == '0) && !r_busy && !h_pending;
  assign host_ready = idle;

  // A read's data is in the bank's output register in the cycle after the
  // handshake, which is exactly when h_pending is high.
  assign host_rvalid = h_pending;
  always_ff @(posedge clk) begin
    if (reset) begin
      h_pending <= 1'b0; h_lane_q <= '0;
    end else begin
      h_pending <= host_valid && host_ready && !host_write;
      if (host_valid && host_ready) h_lane_q <= h_lane;
    end
  end

  generate
    for (g = 0; g < LANES; g++) begin : rd
      assign lane_rdata[g] = lane[g].rdata;
    end
  endgenerate
  assign host_rdata = lane_rdata[h_lane_q];

  logic unused_ok;
  assign unused_ok = &{1'b0, src_x[64:WW], p_end[64:BW], s5_word[WW], r_pat};   // MATCH regs unused when WITH_MATCH = 0
endmodule
