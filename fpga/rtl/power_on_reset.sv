`timescale 1ns/1ps
// Synchronous reset: held for 2^CW cycles after configuration and while the
// (already active-high) button input is pressed. The button is synchronized.
module power_on_reset #(
  parameter int CW = 8
)(
  input  logic clk,
  input  logic button,
  output logic reset
);
  logic [CW-1:0] count = '0;
  logic b_m = 1'b0, b_s = 1'b0;
  always_ff @(posedge clk) begin
    b_m <= button;
    b_s <= b_m;
    if (b_s) count <= '0;
    else if (!(&count)) count <= count + 1'b1;
  end
  assign reset = !(&count);
endmodule
