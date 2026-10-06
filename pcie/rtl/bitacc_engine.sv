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
// Range operations (op 8-14). Each is a barrier: it starts when every earlier
// operation has completed, runs on all lanes at once, and later operations
// start after it. The bit store is therefore always in the state that
// sequential execution gives.
//   bit ranges, bits [a, a + len):
//    8 COUNT   value = number of set bits
//    9 FIND1   value = index of the first set bit;   bit = found
//   10 FIND0   value = index of the first clear bit; bit = found
//   11 SETR, 12 CLEARR, 13 FLIPR: set/clear/invert every bit;
//             value = number of set bits before the operation
//   error = a + len > WORDS * 64                          (no write)
//   word regions, words dst = a .. a+len-1 and src = src .. src+len-1:
//   14 BULK   dst[k] = fn(dst[k], src[k]) for every k, unless dry;
//             fn 0 COPY, 1 AND, 2 OR, 3 XOR, 4 ANDN (dst & ~src);
//             value = number of set bits in the results
//   error = fn > 4 || dst + len > WORDS || src + len > WORDS
//           || the regions overlap without being identical  (no write)
// For range operations without FIND, bit = (value != 0). len = 0 is valid
// (value 0, not found). Undefined opcodes (5-7, 15) are errors.
// An error result has bit = 0 and value = 0.
//
// A range operation processes LANES words per step. Bit ranges step through
// groups of LANES consecutive words (one per lane, same local address). BULK
// pairs dst[k] with src[k], which may live in different lanes: lane i reads
// src element k = j*LANES + ((i - src) mod LANES) at local address
// j + (src + ((i - src) mod LANES)) / LANES, and dst lane m receives it from
// lane (m - delta) mod LANES, delta = (dst - src) mod LANES. formal/lane_map.mlw
// proves these index identities. Each BULK step is a src read, a dst read and
// a write: LANES words per 2 cycles.
//
// The host port reads and writes whole words while the engine is idle
// (host_ready is low while any operation is in flight).
module bitacc_engine #(
  parameter int LANES          = 4,     // power of two, >= 2
  parameter int WORDS_PER_LANE = 512,   // power of two
  parameter int ROB_DEPTH      = 32,    // power of two; max operations in flight
  parameter int FIFO_DEPTH     = 16     // per-lane queue; power of two
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
  input  logic [23:0] cmd_src,          // BULK source word
  input  logic [2:0]  cmd_fn,           // BULK function
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
  localparam int WW = LW + AW;                   // global word index width
  localparam int BW = WW + 6;                    // global bit index width
  localparam int CW = BW + 1;                    // bit count width (0 .. WORDS*64)
  localparam int SW = $clog2(ROB_DEPTH);
  localparam int FW = $clog2(FIFO_DEPTH);

  localparam logic [3:0] OP_SET = 4'd2, OP_CLEAR = 4'd3, OP_TOGGLE = 4'd4;
  localparam logic [3:0] OP_COUNT = 4'd8, OP_FIND1 = 4'd9, OP_FIND0 = 4'd10,
                         OP_SETR = 4'd11, OP_CLEARR = 4'd12, OP_FLIPR = 4'd13, OP_BULK = 4'd14;
  localparam logic [2:0] FN_COPY = 3'd0, FN_AND = 3'd1, FN_OR = 3'd2, FN_XOR = 3'd3, FN_ANDN = 3'd4;

  localparam logic [64:0] STORE_WORDS = 65'(LANES * WORDS_PER_LANE);
  localparam logic [64:0] STORE_BITS  = STORE_WORDS << 6;

  function automatic logic [6:0] popcount64(input logic [63:0] x);
    popcount64 = '0;
    for (int b = 0; b < 64; b++) popcount64 = popcount64 + 7'(x[b]);
  endfunction

  function automatic logic [5:0] ctz64(input logic [63:0] x);  // index of the lowest set bit
    ctz64 = '0;
    for (int b = 63; b >= 0; b--) if (x[b]) ctz64 = 6'(b);
  endfunction

  // ---------------------------------------------------------------- stage 0: accept
  // Registered decode keeps the 64-bit address arithmetic off the dispatch path.
  logic [63:0]   eff;
  logic [57:0]   word;
  logic [64:0]   a_x, len_x, src_x, end_x, send_x;
  logic          c_single, c_range, c_err;
  assign eff    = (cmd_base << 3) + cmd_offset;
  assign word   = eff[63:6];
  assign a_x    = {1'b0, eff};
  assign len_x  = 65'(cmd_len);
  assign src_x  = 65'(cmd_src);
  assign end_x  = a_x + len_x;                   // bit range end, or dst region end
  assign send_x = src_x + len_x;                 // src region end
  assign c_single = cmd_op <= OP_TOGGLE;
  assign c_range  = cmd_op >= OP_COUNT && cmd_op <= OP_BULK;
  always_comb begin
    if (c_single)               c_err = (word >> WW) != '0;
    else if (cmd_op < OP_COUNT) c_err = 1'b1;                    // 5-7
    else if (cmd_op < OP_BULK)  c_err = end_x > STORE_BITS;
    else if (cmd_op == OP_BULK) c_err = cmd_fn > FN_ANDN || end_x > STORE_WORDS || send_x > STORE_WORDS
                                        || (cmd_len != '0 && a_x != src_x && a_x < send_x && src_x < end_x);
    else                        c_err = 1'b1;                    // 15
  end

  logic          d_valid;
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

  logic [SW:0]   inflight;            // descriptors accepted and not yet emitted
  logic [SW-1:0] next_seq;
  logic          d_take;              // stage-1 register consumed this cycle
  logic          accept;

  assign accept    = cmd_valid && cmd_ready;
  // inflight already counts the descriptor held in the decode register.
  assign cmd_ready = (inflight < (SW+1)'(ROB_DEPTH)) && (!d_valid || d_take);

  always_ff @(posedge clk) begin
    if (reset) begin
      d_valid <= 1'b0; next_seq <= '0;
      d_seq <= '0; d_err <= 1'b0; d_range <= 1'b0; d_op <= '0; d_lane <= '0; d_local <= '0; d_bit <= '0;
      d_fn <= '0; d_dry <= 1'b0; d_empty <= 1'b0; d_lo <= '0; d_hi <= '0; d_src <= '0; d_n <= '0;
    end else begin
      if (d_take) d_valid <= 1'b0;
      if (accept) begin
        d_valid  <= 1'b1;
        d_seq    <= next_seq;
        next_seq <= next_seq + 1'b1;
        d_err    <= c_err;
        d_range  <= c_range;
        d_op     <= cmd_op;
        d_lane   <= word[LW-1:0];
        d_local  <= word[WW-1:LW];
        d_bit    <= eff[5:0];
        d_fn     <= cmd_fn;
        d_dry    <= cmd_dry;
        d_empty  <= cmd_len == '0;
        d_lo     <= eff[BW-1:0];
        d_hi     <= BW'(end_x - 65'd1);
        d_src    <= src_x[WW-1:0];
        d_n      <= len_x[WW:0];
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

  // Errors bypass the lanes and go straight to the reorder buffer. A range
  // operation waits until every lane has drained; nothing dispatches while it runs.
  assign r_start = d_valid && !d_err && d_range && !r_busy && l_busy == '0;
  assign d_take  = d_valid && (d_err || r_start || (!d_range && !r_busy && !q_full[d_lane]));
  always_comb begin
    q_push = '0;
    if (d_valid && !d_err && !d_range && !r_busy && !q_full[d_lane]) q_push[d_lane] = 1'b1;
  end

  // ---------------------------------------------------------------- range unit: control
  typedef enum logic [1:0] {R_IDLE, R_ISSUE, R_DRAIN} rstate_t;
  localparam logic [1:0] K_BITS = 2'd0, K_SRC = 2'd1, K_DST = 2'd2;

  rstate_t       r_state;
  logic [SW-1:0] r_seq;
  logic [3:0]    r_op;
  logic [2:0]    r_fn;
  logic          r_dry;
  logic [BW-1:0] r_lo, r_hi;
  logic [WW:0]   r_n;
  logic [LW-1:0] r_delta;             // (dst - src) mod LANES
  logic [AW-1:0] r_g;                 // group (bit ranges) or step j (BULK)
  logic          r_phase;             // BULK: 0 src read, 1 dst read
  logic [CW-1:0] r_acc;
  logic          r_found;
  logic [BW-1:0] r_idx;
  logic          r_done;
  logic          r_find, r_bulk;
  logic [AW-1:0] r_glast;

  assign r_busy  = r_state != R_IDLE;
  assign r_find  = r_op == OP_FIND1 || r_op == OP_FIND0;
  assign r_bulk  = r_op == OP_BULK;
  assign r_glast = r_bulk ? AW'((r_n - 1'b1) >> LW) : r_hi[BW-1:6+LW];

  // issue (S0): one read per lane per cycle
  logic          s0_valid;
  logic [1:0]    s0_kind;
  assign s0_valid = r_state == R_ISSUE && !(r_find && r_found);
  assign s0_kind  = !r_bulk ? K_BITS : (r_phase ? K_DST : K_SRC);

  // pipeline: S1 data from the banks, S2 masked/combined word, S3 count/position
  logic          s1_valid, s2_valid, s3_valid;
  logic [1:0]    s1_kind;
  logic [AW-1:0] s1_g, s2_g, s3_g;
  logic [6:0]    s3_cnt [LANES];
  logic [LANES-1:0] s3_hit;
  logic [5:0]    s3_pos [LANES];
  logic [LW+6:0] s3_sum;              // set bits in this step, all lanes
  logic          s3_any;
  logic [LW-1:0] s3_first;            // lowest lane with a hit
  always_comb begin
    s3_sum = '0; s3_any = 1'b0; s3_first = '0;
    for (int i = 0; i < LANES; i++) s3_sum = s3_sum + (LW+7)'(s3_cnt[i]);
    for (int i = LANES - 1; i >= 0; i--) if (s3_hit[i]) begin s3_any = 1'b1; s3_first = LW'(i); end
  end

  always_ff @(posedge clk) begin
    r_done <= 1'b0;
    if (reset) begin
      r_state <= R_IDLE; r_seq <= '0; r_op <= '0; r_fn <= '0; r_dry <= 1'b0;
      r_lo <= '0; r_hi <= '0; r_n <= '0; r_delta <= '0; r_g <= '0; r_phase <= 1'b0;
      r_acc <= '0; r_found <= 1'b0; r_idx <= '0;
      s1_valid <= 1'b0; s1_kind <= K_BITS; s1_g <= '0;
      s2_valid <= 1'b0; s2_g <= '0; s3_valid <= 1'b0; s3_g <= '0;
    end else begin
      case (r_state)
        R_IDLE: if (r_start) begin
          r_state <= d_empty ? R_DRAIN : R_ISSUE;
          r_seq   <= d_seq;  r_op <= d_op; r_fn <= d_fn; r_dry <= d_dry;
          r_lo    <= d_lo;   r_hi <= d_hi; r_n <= d_n;
          r_delta <= d_lo[LW-1:0] - d_src[LW-1:0];
          r_g     <= d_op == OP_BULK ? '0 : d_lo[BW-1:6+LW];
          r_phase <= 1'b0;
          r_acc   <= '0; r_found <= 1'b0; r_idx <= '0;
        end
        R_ISSUE: begin
          if (r_bulk) begin
            r_phase <= !r_phase;
            if (r_phase) begin
              if (r_g == r_glast) r_state <= R_DRAIN;
              r_g <= r_g + 1'b1;
            end
          end else begin
            if (r_g == r_glast || (r_find && r_found)) r_state <= R_DRAIN;
            r_g <= r_g + 1'b1;
          end
        end
        R_DRAIN: if (!s1_valid && !s2_valid && !s3_valid) begin
          r_state <= R_IDLE;
          r_done  <= 1'b1;
        end
        default: r_state <= R_IDLE;
      endcase

      s1_valid <= s0_valid; s1_kind <= s0_kind; s1_g <= r_g;
      s2_valid <= s1_valid && s1_kind != K_SRC;  s2_g <= s1_g;
      s3_valid <= s2_valid; s3_g <= s2_g;

      // S3: reduce across lanes
      if (s3_valid) begin
        r_acc <= r_acc + CW'(s3_sum);
        if (r_find && !r_found && s3_any) begin
          r_found <= 1'b1;
          r_idx   <= {s3_g, s3_first, s3_pos[s3_first]};
        end
      end
    end
  end

  // ---------------------------------------------------------------- lanes
  logic [LANES-1:0] l_done;
  logic [SW-1:0]    l_seq [LANES];
  logic             l_bit [LANES];
  logic [63:0]      src_q [LANES];    // BULK: src words of the current step, by src lane

  // host access: global word -> lane, local address
  logic [LW-1:0] h_lane;
  logic [AW-1:0] h_local;
  assign h_lane  = host_word[LW-1:0];
  assign h_local = host_word[WW-1:LW];
  logic          h_pending;
  logic [LW-1:0] h_lane_q;

  genvar g;
  generate
    for (g = 0; g < LANES; g++) begin : lane
      // queue
      logic [SW+AW+6+3-1:0] fifo [FIFO_DEPTH];
      logic [FW:0] wp, rp;
      assign q_full[g]  = (wp - rp) == (FW+1)'(FIFO_DEPTH);
      assign q_empty[g] = (wp == rp);
      always_ff @(posedge clk) begin
        if (reset) begin
          wp <= '0; rp <= '0;
        end else begin
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
      // BULK per-lane constants (see the header): dst element offset q, and
      // the local base addresses of the src and dst regions.
      logic [LW-1:0] q_off;
      logic [AW-1:0] sa, da;
      always_ff @(posedge clk) begin
        if (reset) begin
          q_off <= '0; sa <= '0; da <= '0;
        end else if (r_start) begin
          q_off <= LW'(g) - d_lo[LW-1:0];
          sa    <= AW'(((WW+1)'(d_src)    + (WW+1)'(LW'(LW'(g) - d_src[LW-1:0]))) >> LW);
          da    <= AW'(((WW+1)'(d_lo[WW-1:0]) + (WW+1)'(LW'(LW'(g) - d_lo[LW-1:0]))) >> LW);
        end
      end

      logic [AW-1:0] r_raddr;
      always_comb begin
        case (s0_kind)
          K_SRC:   r_raddr = r_g + sa;
          K_DST:   r_raddr = r_g + da;
          default: r_raddr = r_g;
        endcase
      end

      // S1, bit ranges: mask of this lane's word within [r_lo, r_hi]
      logic [WW-1:0] w;
      logic [63:0]   lowm, highm, mask, sel, fillword;
      assign w     = {s1_g, LW'(g)};
      assign lowm  = (w == r_lo[BW-1:6]) ? (~64'd0 << r_lo[5:0]) : ~64'd0;
      assign highm = (w == r_hi[BW-1:6]) ? (~64'd0 >> (6'd63 - r_hi[5:0])) : ~64'd0;
      assign mask  = (w >= r_lo[BW-1:6] && w <= r_hi[BW-1:6]) ? (lowm & highm) : 64'd0;
      assign sel   = (r_op == OP_FIND0 ? ~rdata : rdata) & mask;
      always_comb begin
        case (r_op)
          OP_SETR:   fillword = rdata | mask;
          OP_CLEARR: fillword = rdata & ~mask;
          default:   fillword = rdata ^ mask;     // FLIPR
        endcase
      end

      // S1, BULK dst step: element k = j*LANES + q_off, src word from lane (g - delta)
      logic [63:0] srcw, bulkword;
      logic        kvalid;
      assign srcw   = src_q[LW'(LW'(g) - r_delta)];
      assign kvalid = ((WW+1)'({s1_g, LW'(0)}) + (WW+1)'(q_off)) < r_n;
      always_comb begin
        case (r_fn)
          FN_COPY: bulkword = srcw;
          FN_AND:  bulkword = rdata & srcw;
          FN_OR:   bulkword = rdata | srcw;
          FN_XOR:  bulkword = rdata ^ srcw;
          default: bulkword = rdata & ~srcw;      // ANDN
        endcase
      end

      logic          r_we;
      logic [AW-1:0] r_waddr;
      logic [63:0]   r_wdata;
      always_comb begin
        r_we = 1'b0; r_waddr = s1_g; r_wdata = fillword;
        if (s1_valid && s1_kind == K_BITS)
          r_we = (r_op == OP_SETR || r_op == OP_CLEARR || r_op == OP_FLIPR) && mask != '0;
        else if (s1_valid && s1_kind == K_DST) begin
          r_we = kvalid && !r_dry; r_waddr = s1_g + da; r_wdata = bulkword;
        end
      end

      logic [63:0] s2_word;
      always_ff @(posedge clk) begin
        if (reset) begin
          src_q[g] <= '0; s2_word <= '0; s3_cnt[g] <= '0; s3_hit[g] <= 1'b0; s3_pos[g] <= '0;
        end else begin
          if (s1_valid && s1_kind == K_SRC) src_q[g] <= rdata;
          if (s1_valid && s1_kind != K_SRC) s2_word <= (s1_kind == K_DST) ? (kvalid ? bulkword : 64'd0) : sel;
          if (s2_valid) begin
            s3_cnt[g] <= popcount64(s2_word);
            s3_hit[g] <= s2_word != '0;
            s3_pos[g] <= ctz64(s2_word);
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
          raddr = r_raddr; we = r_we; waddr = r_waddr; wdata = r_wdata;
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
  logic                 emit;
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
      inflight <= inflight + (SW+1)'(accept) - (SW+1)'(emit);
    end
  end

  // ---------------------------------------------------------------- host port
  assign idle       = (inflight == '0) && !d_valid && (l_busy == '0) && !r_busy && !h_pending;
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

  logic [63:0] lane_rdata [LANES];
  generate
    for (g = 0; g < LANES; g++) begin : rd
      assign lane_rdata[g] = lane[g].rdata;
    end
  endgenerate
  assign host_rdata = lane_rdata[h_lane_q];

  logic unused_ok;
  assign unused_ok = &{1'b0, cmd_src, cmd_len, src_x[64:WW], len_x[64:WW+1]};
endmodule
