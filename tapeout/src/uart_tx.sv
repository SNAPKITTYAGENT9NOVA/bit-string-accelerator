// 8N1 UART transmitter. Load with start when ready is high.
module uart_tx #(
  parameter int CW = 10                  // width of cpb
)(
  input  logic          clk,
  input  logic          reset,
  input  logic [CW-1:0] cpb,             // clocks per bit (>= 4)
  input  logic       start,
  input  logic [7:0] data,
  output logic       ready,
  output logic       tx
);
  logic [CW-1:0] FULL;
  assign FULL = cpb - 1'b1;

  // LSB first: start, data[7:0], stop, then one guard bit so ready rises only
  // after the stop bit has lasted a full bit time.
  logic [10:0] shreg;
  logic [3:0] left;                 // bit times still to send
  logic [CW-1:0] cnt;
  // The line is stored inverted: FPGA flip-flops power up low, so tx is idle
  // high from configuration, before the first reset edge (a low line would be a
  // start bit, i.e. a junk byte, to the host). No initial value is needed.
  logic tx_n;
  assign tx = !tx_n;

  assign ready = (left == 0);

  always_ff @(posedge clk) begin
    if (reset) begin
      tx_n <= 1'b0; left <= '0; cnt <= '0; shreg <= '1;
    end else if (left == 0) begin
      tx_n <= 1'b0;
      if (start) begin
        shreg <= {2'b11, data, 1'b0};
        left <= 4'd11;
        cnt <= '0;
      end
    end else if (cnt == 0) begin
      tx_n <= !shreg[0];
      shreg <= {1'b1, shreg[10:1]};
      left <= left - 1'b1;
      cnt <= FULL;
    end else begin
      cnt <= cnt - 1'b1;
    end
  end
endmodule
