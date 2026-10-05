// ULX3S (Lattice ECP5 LFE5U-25F/45F/85F, 25 MHz). UART through the on-board FTDI
// at 115200 baud. led[0]: last operation reported an error, led[1]: busy,
// led[7]: heartbeat. btn[0] (PWR, active low) resets.
module ulx3s_top (
  input  logic       clk_25mhz,
  input  logic [0:0] btn,
  input  logic       ftdi_txd,    // FTDI -> FPGA
  output logic       ftdi_rxd,    // FPGA -> FTDI
  output logic [7:0] led,
  output logic       wifi_gpio0   // held high so the ESP32 does not take over
);
  logic reset, led_busy, led_error;
  logic [24:0] beat = '0;

  power_on_reset u_por (.clk(clk_25mhz), .button(!btn[0]), .reset);

  fpga_top #(.CLKS_PER_BIT(217)) u_top (       // 25 MHz / 115200 = 217.0
    .clk(clk_25mhz), .reset, .uart_rx(ftdi_txd), .uart_tx(ftdi_rxd), .led_busy, .led_error);

  always_ff @(posedge clk_25mhz) beat <= beat + 1'b1;
  assign led = {beat[24], 5'd0, led_busy, led_error};
  assign wifi_gpio0 = 1'b1;
endmodule
