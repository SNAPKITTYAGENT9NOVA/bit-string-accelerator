// Register-bounded wrapper for timing bitacc_pcie_core with the open-source
// Artix-7 flow (pcie/timing/Makefile). The core's ~470 I/O bits do not fit a
// package, and in the SoC they connect to LitePCIe registers anyway, so here
// every input comes from a register (a serial shift chain) and every output
// goes into a register (XOR-folded to a few pins). The register-to-register
// paths inside the core are the ones that matter for 125 MHz.
module timing_top #(
  parameter int LANES          = 8,
  parameter int WORDS_PER_LANE = 2048,
  parameter bit WITH_MATCH     = 1'b1,
  parameter int MATCH_LANES    = LANES
)(
  input  logic       clk,
  input  logic       rst,
  input  logic       sin,
  input  logic [3:0] ctl,
  output logic [7:0] sout
);
  localparam int WW = $clog2(LANES * WORDS_PER_LANE);

  logic [191+WW:0] sh;
  logic            r_rst, in_valid, out_ready, wstb, rstb;
  always_ff @(posedge clk) begin
    sh <= {sh[190+WW:0], sin};
    r_rst <= rst;
    {in_valid, out_ready, wstb, rstb} <= ctl;
  end

  logic         in_ready, out_valid, host_rdata_valid, host_busy, idle;
  logic [127:0] out_data;
  logic [63:0]  host_rdata;
  logic [31:0]  ops_accepted, results_sent;

  bitacc_pcie_core #(.LANES(LANES), .WORDS_PER_LANE(WORDS_PER_LANE), .WITH_MATCH(WITH_MATCH),
                   .MATCH_LANES(MATCH_LANES)) core (
    .clk, .reset(r_rst),
    .in_valid, .in_ready, .in_data(sh[127:0]),
    .out_valid, .out_ready, .out_data,
    .host_word(sh[192 +: WW]), .host_wdata(sh[191:128]),
    .host_write_stb(wstb), .host_read_stb(rstb),
    .host_rdata, .host_rdata_valid, .host_busy,
    .idle, .ops_accepted, .results_sent);

  always_ff @(posedge clk)
    sout <= {^out_data[127:64], ^out_data[63:0], out_valid, in_ready,
             ^host_rdata, host_rdata_valid, host_busy, idle ^ (^ops_accepted) ^ (^results_sent)};
endmodule
