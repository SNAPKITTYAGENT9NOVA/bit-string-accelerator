// 8N1 UART receiver. cpb = clocks per bit = clock frequency / baud rate (>= 4).
// valid pulses for one cycle with the received byte in data.
module uart_rx #(
  parameter int CW = 10                  // width of cpb
)(
  input  logic          clk,
  input  logic          reset,
  input  logic [CW-1:0] cpb,
  input  logic          rx,
  output logic          valid,
  output logic [7:0]    data
);
  logic [CW-1:0] FULL, HALF;
  assign FULL = cpb - 1'b1;
  assign HALF = cpb >> 1;

  logic rx_m, rx_s;                 // two-flop synchronizer
  logic [1:0] state;                // 0 idle, 1 start, 2 data, 3 stop
  logic [CW-1:0] cnt;
  logic [2:0] bitn;

  always_ff @(posedge clk) begin
    rx_m <= rx;
    rx_s <= rx_m;
    valid <= 1'b0;
    if (reset) begin
      state <= 2'd0; cnt <= '0; bitn <= '0; data <= '0;
      rx_m <= 1'b1; rx_s <= 1'b1;
    end else begin
      case (state)
        2'd0: if (!rx_s) begin state <= 2'd1; cnt <= HALF; end
        2'd1: if (cnt == 0) begin
                if (!rx_s) begin state <= 2'd2; cnt <= FULL; bitn <= '0; end
                else state <= 2'd0;              // glitch, not a start bit
              end else cnt <= cnt - 1'b1;
        2'd2: if (cnt == 0) begin
                data <= {rx_s, data[7:1]};
                cnt <= FULL;
                if (bitn == 3'd7) state <= 2'd3;
                bitn <= bitn + 1'b1;
              end else cnt <= cnt - 1'b1;
        default: if (cnt == 0) begin
                   state <= 2'd0;
                   valid <= rx_s;                // drop bytes with a bad stop bit
                 end else cnt <= cnt - 1'b1;
      endcase
    end
  end
endmodule
