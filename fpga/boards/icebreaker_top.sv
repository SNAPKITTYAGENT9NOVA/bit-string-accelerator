`timescale 1ns/1ps
// iCEBreaker (Lattice iCE40UP5K-SG48, 12 MHz). UART on the FTDI second channel
// at 115200 baud. Red LED: last operation reported an error. Green LED: heartbeat.
module icebreaker_top (
  input  logic CLK,
  input  logic BTN_N,
  input  logic RX,
  output logic TX,
  output logic LEDR_N,
  output logic LEDG_N
);
  logic reset, led_busy, led_error;
  logic [23:0] beat = '0;

  power_on_reset u_por (.clk(CLK), .button(!BTN_N), .reset);

  fpga_top #(.CLKS_PER_BIT(104)) u_top (       // 12 MHz / 115200 = 104.2
    .clk(CLK), .reset, .uart_rx(RX), .uart_tx(TX), .led_busy, .led_error);

  always_ff @(posedge CLK) beat <= beat + 1'b1;
  assign LEDR_N = !led_error;
  assign LEDG_N = !(beat[23] || led_busy);
endmodule
