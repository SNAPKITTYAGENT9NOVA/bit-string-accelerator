// Tiny Tapeout top: bit_accelerator + 4 x 64-bit words of RAM, driven over a
// UART with the same protocol as fpga/rtl/fpga_top.sv (see fpga/README.md):
//
//   'P'                           -> 'B'                     ping
//   'W' idx[1] data[8]            -> 'K'                     write word idx
//   'R' idx[1]                    -> data[8]                 read word idx
//   'X' op[1] base[8] offset[8]   -> 0xA0 | error<<1 | bit   run one operation
//   anything else                 -> '?'
//
// Multi-byte fields are little-endian. The RAM holds byte addresses 0..31; any
// other address answers with mem_fault (error). idx is taken modulo 4.
//
// Pins:
//   ui_in[3]                      UART RX (115200 8N1 at the default divisor)
//   ui_in[7:4], ui_in[2:0]        baud divisor d = {ui_in[7:4], ui_in[2:0]}:
//                                 clocks per bit = 4*d, or 104 when d = 0
//   uo_out[4]                     UART TX
//   uo_out[0]                     busy (operation in progress)
//   uo_out[1]                     error (last operation)
//   uo_out[2]                     result bit (last operation)
//
// Compared with fpga_top, operands are received straight into the registers
// the core reads, and read replies are streamed from the RAM, so no byte is
// stored twice.
module tt_um_snapkittyagent9nova_bitacc (
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
);
  localparam int DEPTH = 4;

  logic reset;
  assign reset = !rst_n;

  // ------------------------------------------------------------------ UART
  logic [6:0] div;
  logic [9:0] cpb;
  assign div = {ui_in[7:4], ui_in[2:0]};
  assign cpb = (div == 7'd0) ? 10'd104 : {1'b0, div, 2'b00};

  logic       rx_valid, tx_start, tx_ready, tx;
  logic [7:0] rx_data, tx_data;

  uart_rx u_rx (.clk, .reset, .cpb, .rx(ui_in[3]), .valid(rx_valid), .data(rx_data));
  uart_tx u_tx (.clk, .reset, .cpb, .start(tx_start), .data(tx_data), .ready(tx_ready), .tx);

  // ------------------------------------------------------------------ registers
  typedef enum logic [2:0] {S_CMD, S_ARGS, S_HOST_WRITE, S_START, S_EXEC, S_SEND} state_t;
  state_t state;

  logic [7:0]  cmd;
  logic [4:0]  argi, nargs;
  logic [2:0]  arg0;               // word index (W, R; low 2 bits) or opcode (X)
  logic [63:0] base;               // X: base address; W: data
  logic [63:0] offset;             // X: bit offset
  logic [7:0]  status;             // one-byte reply
  logic [3:0]  replyi, nreply;
  logic        last_error, last_bit;

  // ------------------------------------------------------------------ core
  logic        op_ready, result_valid, result_bit, acc_error;
  logic        mem_valid, mem_write, mem_rvalid, mem_fault;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0]  mem_wstrb;

  bit_accelerator u_acc (
    .clk, .reset,
    .op_valid(state == S_START), .op_ready,
    .base_address(base), .bit_offset(offset), .operation(arg0[2:0]),
    .result_valid, .result_bit, .error(acc_error),
    .mem_valid, .mem_write, .mem_addr, .mem_wdata, .mem_wstrb,
    .mem_ready(state == S_EXEC), .mem_rvalid, .mem_rdata, .mem_fault);

  // ------------------------------------------------------------------ RAM (flip-flops)
  logic [63:0] ram [0:DEPTH-1];
  logic        in_range;
  logic [1:0]  acc_idx;
  assign in_range  = (mem_addr[63:5] == '0);
  assign acc_idx   = mem_addr[4:3];
  assign mem_rdata = ram[acc_idx];            // address is held stable by the core

  always_ff @(posedge clk) begin
    if (state == S_HOST_WRITE) ram[arg0[1:0]] <= base;
    else if (state == S_EXEC && mem_valid && mem_write && in_range) ram[acc_idx] <= mem_wdata;
  end

  // ------------------------------------------------------------------ reply stream
  logic [63:0] rd_word;
  assign rd_word  = ram[arg0[1:0]];
  assign tx_data  = (cmd == 8'h52) ? rd_word[{replyi[2:0], 3'b000} +: 8] : status;
  assign tx_start = (state == S_SEND) && tx_ready && (replyi < nreply);

  // ------------------------------------------------------------------ control
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_CMD; cmd <= '0; argi <= '0; nargs <= '0; arg0 <= '0;
      base <= '0; offset <= '0; status <= '0; replyi <= '0; nreply <= '0;
      last_error <= 1'b0; last_bit <= 1'b0; mem_rvalid <= 1'b0; mem_fault <= 1'b0;
    end else begin
      mem_rvalid <= 1'b0;
      mem_fault  <= 1'b0;
      case (state)
        S_CMD: if (rx_valid) begin
          cmd <= rx_data; argi <= '0; replyi <= '0;
          case (rx_data)
            8'h50: begin status <= 8'h42; nreply <= 4'd1; state <= S_SEND; end  // 'P'
            8'h57: begin nargs <= 5'd9;  state <= S_ARGS; end                   // 'W'
            8'h52: begin nargs <= 5'd1;  state <= S_ARGS; end                   // 'R'
            8'h58: begin nargs <= 5'd17; state <= S_ARGS; end                   // 'X'
            default: begin status <= 8'h3F; nreply <= 4'd1; state <= S_SEND; end
          endcase
        end
        S_ARGS: if (rx_valid) begin
          // byte 0 -> arg0, bytes 1..8 -> base, bytes 9..16 -> offset
          if (argi == 5'd0) arg0 <= rx_data[2:0];
          else if (argi <= 5'd8) base[{argi[2:0] - 3'd1, 3'b000} +: 8] <= rx_data;
          else offset[{argi[2:0] - 3'd1, 3'b000} +: 8] <= rx_data;
          argi <= argi + 1'b1;
          if (argi + 1'b1 == nargs) begin
            case (cmd)
              8'h57:   state <= S_HOST_WRITE;
              8'h52:   begin nreply <= 4'd8; state <= S_SEND; end
              default: state <= S_START;
            endcase
          end
        end
        S_HOST_WRITE: begin                       // RAM written this cycle
          status <= 8'h4B; nreply <= 4'd1; state <= S_SEND;
        end
        S_START: if (op_ready) state <= S_EXEC;   // operands are already stable
        S_EXEC: begin
          if (mem_valid && !mem_write) begin
            if (in_range) mem_rvalid <= 1'b1; else mem_fault <= 1'b1;
          end
          if (mem_valid && mem_write && !in_range) mem_fault <= 1'b1;
          if (result_valid) begin
            status <= 8'hA0 | {6'd0, acc_error, result_bit};
            last_error <= acc_error;
            if (!acc_error) last_bit <= result_bit;
            nreply <= 4'd1; state <= S_SEND;
          end
        end
        S_SEND: begin
          if (tx_start) replyi <= replyi + 1'b1;
          else if (replyi == nreply && tx_ready) state <= S_CMD;
        end
        default: state <= S_CMD;
      endcase
    end
  end

  assign uo_out  = {3'b000, tx, 1'b0, last_bit, last_error, (state == S_START || state == S_EXEC)};
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  logic _unused;
  assign _unused = &{1'b0, ena, uio_in, mem_wstrb, mem_addr[2:0]};
endmodule
