// Parallel bit-operation engine.
//
// A stream of operation descriptors (op, base, offset) is executed by LANES
// lanes, each owning one bank of the bit store. Word w lives in lane w % LANES
// at local address w / LANES, so all operations on one word run in one lane,
// in arrival order. Operations on different words commute, so the results and
// the final memory equal those of executing the stream one at a time on the
// reference core rtl/bit_accelerator.sv (checked by pcie/tb/tb_engine.sv).
//
//   effective bit = (base << 3) + offset           (mod 2^64, as in the core)
//   word          = effective bit >> 6, bit index = effective bit[5:0]
//   error         = word >= LANES*WORDS_PER_LANE || op > 4   (no write)
//
// Results leave in descriptor order through a reorder buffer: one result per
// descriptor, {error, bit}; bit is 0 when error is set.
//
// The host port reads and writes whole words while the engine is idle
// (host_ready is low while any operation is in flight).
module bitacc_engine #(
  parameter int LANES          = 4,     // power of two
  parameter int WORDS_PER_LANE = 512,   // power of two
  parameter int ROB_DEPTH      = 32,    // power of two; max operations in flight
  parameter int FIFO_DEPTH     = 16     // per-lane queue; power of two
)(
  input  logic        clk,
  input  logic        reset,

  // descriptors in
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [2:0]  cmd_op,
  input  logic [63:0] cmd_base,
  input  logic [63:0] cmd_offset,

  // results out, in descriptor order
  output logic        res_valid,
  input  logic        res_ready,
  output logic        res_error,
  output logic        res_bit,

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
  localparam int SW = $clog2(ROB_DEPTH);
  localparam int FW = $clog2(FIFO_DEPTH);

  localparam logic [2:0] OP_SET = 3'd2, OP_CLEAR = 3'd3, OP_TOGGLE = 3'd4;

  // ---------------------------------------------------------------- stage 0: accept
  // Registered decode keeps the 64-bit adder off the dispatch path.
  logic          d_valid;
  logic [SW-1:0] d_seq;
  logic          d_err;
  logic [LW-1:0] d_lane;
  logic [AW-1:0] d_local;
  logic [5:0]    d_bit;
  logic [2:0]    d_op;

  logic [63:0]   eff;
  logic [57:0]   word;
  assign eff  = (cmd_base << 3) + cmd_offset;
  assign word = eff[63:6];

  logic [SW:0]   inflight;          // descriptors accepted and not yet emitted
  logic [SW-1:0] next_seq;
  logic          d_take;            // stage-1 register consumed this cycle
  logic          accept;

  assign accept    = cmd_valid && cmd_ready;
  // inflight already counts the descriptor held in the decode register.
  assign cmd_ready = (inflight < (SW+1)'(ROB_DEPTH)) && (!d_valid || d_take);

  always_ff @(posedge clk) begin
    if (reset) begin
      d_valid <= 1'b0; next_seq <= '0;
      d_seq <= '0; d_err <= 1'b0; d_lane <= '0; d_local <= '0; d_bit <= '0; d_op <= '0;
    end else begin
      if (d_take) d_valid <= 1'b0;
      if (accept) begin
        d_valid <= 1'b1;
        d_seq   <= next_seq;
        next_seq <= next_seq + 1'b1;
        d_err   <= (word >> WW) != '0 || cmd_op > OP_TOGGLE;
        d_lane  <= word[LW-1:0];
        d_local <= word[WW-1:LW];
        d_bit   <= eff[5:0];
        d_op    <= cmd_op;
      end
    end
  end

  // ---------------------------------------------------------------- lane queues
  logic [LANES-1:0] q_full, q_empty;
  logic [LANES-1:0] q_push, q_pop;
  logic [SW-1:0]    q_seq   [LANES];
  logic [AW-1:0]    q_local [LANES];
  logic [5:0]       q_bit   [LANES];
  logic [2:0]       q_op    [LANES];

  // Errors bypass the lanes and go straight to the reorder buffer.
  assign d_take = d_valid && (d_err || !q_full[d_lane]);
  always_comb begin
    q_push = '0;
    if (d_valid && !d_err && !q_full[d_lane]) q_push[d_lane] = 1'b1;
  end

  // ---------------------------------------------------------------- lanes
  logic [LANES-1:0] l_done;
  logic [SW-1:0]    l_seq [LANES];
  logic             l_bit [LANES];
  logic [LANES-1:0] l_busy;

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
            fifo[wp[FW-1:0]] <= {d_seq, d_local, d_bit, d_op};
            wp <= wp + 1'b1;
          end
          if (q_pop[g]) rp <= rp + 1'b1;
        end
      end
      assign {q_seq[g], q_local[g], q_bit[g], q_op[g]} = fifo[rp[FW-1:0]];

      // bank: single port, synchronous read (block RAM)
      logic [63:0] bank [WORDS_PER_LANE];
      logic        we;
      logic [AW-1:0] addr;
      logic [63:0] wdata, rdata;
      always_ff @(posedge clk) begin
        if (we) bank[addr] <= wdata;
        rdata <= bank[addr];
      end

      // execute: READ (address presented) -> MODIFY (data back, write) -> next
      logic          st_mod;          // 0: read cycle, 1: modify cycle
      logic [SW-1:0] x_seq;
      logic [AW-1:0] x_local;
      logic [5:0]    x_bit;
      logic [2:0]    x_op;
      logic [63:0]   onehot, newword;
      logic          oldbit, newbit, writes;

      assign onehot = 64'd1 << x_bit;
      assign oldbit = rdata[x_bit];
      always_comb begin
        case (x_op)
          OP_SET:    begin newword = rdata | onehot;  newbit = 1'b1;    writes = 1'b1; end
          OP_CLEAR:  begin newword = rdata & ~onehot; newbit = 1'b0;    writes = 1'b1; end
          OP_TOGGLE: begin newword = rdata ^ onehot;  newbit = !oldbit; writes = 1'b1; end
          default:   begin newword = rdata;           newbit = oldbit;  writes = 1'b0; end
        endcase
      end

      assign q_pop[g]  = !q_empty[g] && !st_mod;
      assign l_busy[g] = st_mod || !q_empty[g];

      // port mux: lane owns the bank unless the engine is idle and the host uses it
      always_comb begin
        we = 1'b0; addr = q_local[g]; wdata = newword;
        if (st_mod) begin
          addr = x_local; we = writes;
        end else if (q_empty[g] && host_valid && host_ready && h_lane == LW'(g)) begin
          addr = h_local; we = host_write; wdata = host_wdata;
        end
      end

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
    end
  endgenerate

  // ---------------------------------------------------------------- reorder buffer
  logic [ROB_DEPTH-1:0] rob_full;
  logic [ROB_DEPTH-1:0] rob_err, rob_bit;
  logic [SW-1:0]        head;
  logic                 emit;

  assign res_valid = rob_full[head];
  assign res_error = rob_err[head];
  assign res_bit   = rob_bit[head];
  assign emit      = res_valid && res_ready;

  always_ff @(posedge clk) begin
    if (reset) begin
      rob_full <= '0; rob_err <= '0; rob_bit <= '0; head <= '0; inflight <= '0;
    end else begin
      if (emit) begin
        rob_full[head] <= 1'b0;
        head <= head + 1'b1;
      end
      if (d_take && d_err) begin
        rob_full[d_seq] <= 1'b1; rob_err[d_seq] <= 1'b1; rob_bit[d_seq] <= 1'b0;
      end
      for (int i = 0; i < LANES; i++) begin
        if (l_done[i]) begin
          rob_full[l_seq[i]] <= 1'b1; rob_err[l_seq[i]] <= 1'b0; rob_bit[l_seq[i]] <= l_bit[i];
        end
      end
      inflight <= inflight + (SW+1)'(accept) - (SW+1)'(emit);
    end
  end

  // ---------------------------------------------------------------- host port
  assign idle       = (inflight == '0) && !d_valid && (l_busy == '0) && !h_pending;
  assign host_ready = (inflight == '0) && !d_valid && (l_busy == '0) && !h_pending;

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
endmodule
