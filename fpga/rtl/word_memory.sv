// Single-port 64-bit word memory with synchronous read (maps to block RAM).
module word_memory #(
  parameter int DEPTH = 256
)(
  input  logic                     clk,
  input  logic                     we,
  input  logic [$clog2(DEPTH)-1:0] addr,
  input  logic [63:0]              wdata,
  output logic [63:0]              rdata
);
  logic [63:0] mem [0:DEPTH-1];
  always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    rdata <= mem[addr];
  end
endmodule
