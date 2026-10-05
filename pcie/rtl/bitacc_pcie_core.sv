// PCIe-facing wrapper around bitacc_engine: 128-bit DMA streams and a small
// register interface. Transport-independent: LiteX/LitePCIe connects the
// streams to its DMA reader (host -> card) and writer (card -> host), but any
// 128-bit valid/ready stream source works.
//
// Descriptor (one per 128-bit input beat, little-endian), format version 2:
//   [63:0]    a: bit address (single-bit and bit-range operations; the host
//             computes (base << 3) + offset), or dst word (BULK)
//   [67:64]   opcode: 0 GET, 1 TEST, 2 SET, 3 CLEAR, 4 TOGGLE,
//             8 COUNT, 9 FIND1, 10 FIND0, 11 SETR, 12 CLEARR, 13 FLIPR, 14 BULK,
//             5-7 and 15 undefined (no write, result "error")
//   [68]      dry: BULK computes and counts without writing
//   [71:69]   fn: BULK function (0 COPY, 1 AND, 2 OR, 3 XOR, 4 ANDN)
//   [103:72]  len: range length in bits, or in words for BULK
//   [127:104] src word (BULK)
// Semantics and errors: see bitacc_engine.sv.
//
// Results: 8 bytes per descriptor, in descriptor order, 2 per output beat
// (bytes 0-7 of a beat = the first descriptor of the pair):
//   [7:0]   0xA0 | error << 1 | bit   (same status byte as the UART builds)
//   [63:8]  value (range operations; 0 otherwise)
// A batch must hold an even number of descriptors; hosts pad with opcode 7
// (no write, result "error") and drop the padding results.
//
// Registers (driven by CSRs in the SoC):
//   host_word / host_wdata / host_write_stb / host_read_stb : word access to
//   the bit store, accepted only while idle; host_rdata valid when
//   host_rdata_valid rises (sticky until the next access).
module bitacc_pcie_core #(
  parameter int LANES          = 8,
  parameter int WORDS_PER_LANE = 2048,
  parameter int ROB_DEPTH      = 32
)(
  input  logic         clk,
  input  logic         reset,

  input  logic         in_valid,
  output logic         in_ready,
  input  logic [127:0] in_data,

  output logic         out_valid,
  input  logic         out_ready,
  output logic [127:0] out_data,

  input  logic [$clog2(LANES*WORDS_PER_LANE)-1:0] host_word,
  input  logic [63:0]  host_wdata,
  input  logic         host_write_stb,
  input  logic         host_read_stb,
  output logic [63:0]  host_rdata,
  output logic         host_rdata_valid,
  output logic         host_busy,          // an access is pending

  output logic         idle,
  output logic [31:0]  ops_accepted,
  output logic [31:0]  results_sent
);
  localparam int WW = $clog2(LANES * WORDS_PER_LANE);

  // ---------------------------------------------------------------- engine
  logic        res_valid, res_ready, res_error, res_bit;
  logic [55:0] res_value;
  logic        h_valid, h_ready, h_write, h_rvalid;
  logic [WW-1:0] h_word;
  logic [63:0] h_wdata, h_rdata;
  logic        eng_idle;

  bitacc_engine #(.LANES(LANES), .WORDS_PER_LANE(WORDS_PER_LANE), .ROB_DEPTH(ROB_DEPTH)) u_engine (
    .clk, .reset,
    .cmd_valid(in_valid), .cmd_ready(in_ready),
    .cmd_op(in_data[67:64]), .cmd_base(64'd0), .cmd_offset(in_data[63:0]),
    .cmd_len(in_data[103:72]), .cmd_src(in_data[127:104]), .cmd_fn(in_data[71:69]), .cmd_dry(in_data[68]),
    .res_valid, .res_ready, .res_error, .res_bit, .res_value,
    .host_valid(h_valid), .host_ready(h_ready), .host_write(h_write),
    .host_word(h_word), .host_wdata(h_wdata),
    .host_rvalid(h_rvalid), .host_rdata(h_rdata),
    .idle(eng_idle));

  // ---------------------------------------------------------------- result packer
  logic [127:0] pack;
  logic         fill;              // results already in pack
  logic         full;              // pack holds 2 results waiting for out_ready

  // A beat leaving this cycle frees the pack for the next result.
  assign res_ready = !full || out_ready;
  assign out_valid = full;
  assign out_data  = pack;

  always_ff @(posedge clk) begin
    if (reset) begin
      pack <= '0; fill <= '0; full <= 1'b0;
    end else begin
      if (full && out_ready) full <= 1'b0;
      if (res_valid && res_ready) begin
        pack[{fill, 6'b000000} +: 64] <= {res_value, 6'b101000, res_error, res_bit};
        fill <= !fill;
        if (fill) full <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- host word access
  // A strobe is latched and issued when the engine is idle.
  logic          pend, pend_write;
  logic [WW-1:0] pend_word;
  logic [63:0]   pend_wdata;

  assign h_valid   = pend;
  assign h_write   = pend_write;
  assign h_word    = pend_word;
  assign h_wdata   = pend_wdata;
  assign host_busy = pend;

  always_ff @(posedge clk) begin
    if (reset) begin
      pend <= 1'b0; pend_write <= 1'b0; pend_word <= '0; pend_wdata <= '0;
      host_rdata <= '0; host_rdata_valid <= 1'b0;
    end else begin
      if (!pend && (host_write_stb || host_read_stb)) begin
        pend       <= 1'b1;
        pend_write <= host_write_stb;
        pend_word  <= host_word;
        pend_wdata <= host_wdata;
        host_rdata_valid <= 1'b0;
      end else if (pend && h_ready) begin
        pend <= 1'b0;
      end
      if (h_rvalid) begin
        host_rdata <= h_rdata;
        host_rdata_valid <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- status
  assign idle = eng_idle && !full && !fill && !pend;

  always_ff @(posedge clk) begin
    if (reset) begin
      ops_accepted <= '0; results_sent <= '0;
    end else begin
      if (in_valid && in_ready) ops_accepted <= ops_accepted + 1'b1;
      if (out_valid && out_ready) results_sent <= results_sent + 32'd2;
    end
  end
endmodule
