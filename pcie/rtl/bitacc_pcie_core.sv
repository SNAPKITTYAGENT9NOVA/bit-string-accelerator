// PCIe-facing wrapper around bitacc_engine: 128-bit DMA streams and a small
// register interface. Transport-independent: LiteX/LitePCIe connects the
// streams to its DMA reader (host -> card) and writer (card -> host), but any
// 128-bit valid/ready stream source works.
//
// Descriptor (one per 128-bit input beat):
//   [63:0]    effective bit address   (host computes (base << 3) + offset)
//   [66:64]   opcode                  (0 GET, 1 TEST, 2 SET, 3 CLEAR, 4 TOGGLE, 5-7 no-op error)
//   [127:67]  reserved, ignored
//
// Results: one byte per descriptor, in descriptor order, 16 per output beat
// (byte i of a beat = result of the i-th descriptor in that group of 16):
//   0xA0 | error << 1 | bit           (same status byte as the UART builds)
// A batch must hold a multiple of 16 descriptors; hosts pad with opcode 7
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
  logic        h_valid, h_ready, h_write, h_rvalid;
  logic [WW-1:0] h_word;
  logic [63:0] h_wdata, h_rdata;
  logic        eng_idle;

  bitacc_engine #(.LANES(LANES), .WORDS_PER_LANE(WORDS_PER_LANE), .ROB_DEPTH(ROB_DEPTH)) u_engine (
    .clk, .reset,
    .cmd_valid(in_valid), .cmd_ready(in_ready),
    .cmd_op(in_data[66:64]), .cmd_base(64'd0), .cmd_offset(in_data[63:0]),
    .res_valid, .res_ready, .res_error, .res_bit,
    .host_valid(h_valid), .host_ready(h_ready), .host_write(h_write),
    .host_word(h_word), .host_wdata(h_wdata),
    .host_rvalid(h_rvalid), .host_rdata(h_rdata),
    .idle(eng_idle));

  // ---------------------------------------------------------------- result packer
  logic [127:0] pack;
  logic [3:0]   fill;              // bytes already in pack
  logic         full;              // pack holds 16 bytes waiting for out_ready

  assign res_ready = !full;
  assign out_valid = full;
  assign out_data  = pack;

  always_ff @(posedge clk) begin
    if (reset) begin
      pack <= '0; fill <= '0; full <= 1'b0;
    end else begin
      if (full && out_ready) full <= 1'b0;
      if (res_valid && res_ready) begin
        pack[{fill, 3'b000} +: 8] <= 8'hA0 | {6'd0, res_error, res_bit};
        fill <= fill + 1'b1;
        if (fill == 4'd15) full <= 1'b1;
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

  logic unused_ok;
  assign unused_ok = &{1'b0, in_data[127:67]};   // reserved descriptor bits

  // ---------------------------------------------------------------- status
  assign idle = eng_idle && !full && fill == 4'd0 && !pend;

  always_ff @(posedge clk) begin
    if (reset) begin
      ops_accepted <= '0; results_sent <= '0;
    end else begin
      if (in_valid && in_ready) ops_accepted <= ops_accepted + 1'b1;
      if (out_valid && out_ready) results_sent <= results_sent + 32'd16;
    end
  end
endmodule
