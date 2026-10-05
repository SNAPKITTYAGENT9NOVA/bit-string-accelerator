// Board-independent hardware top: bit_accelerator + 256 x 64-bit block RAM,
// controlled over a UART (8N1). All multi-byte fields are little-endian.
//
//   host -> FPGA                         FPGA -> host
//   'P'                                  'B'                       ping
//   'W' idx[1] data[8]                   'K'                       write word idx
//   'R' idx[1]                           data[8]                   read word idx
//   'X' op[1] base[8] offset[8]          0xA0 | error<<1 | bit     run one operation
//   anything else                        '?'
//
// The accelerator sees the RAM at byte addresses 0 .. DEPTH*8-1. Any other
// address answers with mem_fault, so the error path works on hardware.
module fpga_top #(
  parameter int CLKS_PER_BIT = 104,     // clock Hz / baud
  parameter int DEPTH = 256             // words; power of two
)(
  input  logic clk,
  input  logic reset,                   // synchronous, active high
  input  logic uart_rx,
  output logic uart_tx,
  output logic led_busy,                // operation in progress
  output logic led_error                // last operation reported error
);
  localparam int AW = $clog2(DEPTH);

  // ------------------------------------------------------------- UART
  logic       rx_valid;
  logic [7:0] rx_data;
  logic       tx_start, tx_ready;
  logic [7:0] tx_data;

  localparam logic [9:0] CPB = 10'(CLKS_PER_BIT);
  uart_rx u_rx (
    .clk, .reset, .cpb(CPB), .rx(uart_rx), .valid(rx_valid), .data(rx_data));
  uart_tx u_tx (
    .clk, .reset, .cpb(CPB), .start(tx_start), .data(tx_data), .ready(tx_ready), .tx(uart_tx));

  // ------------------------------------------------------------- accelerator
  logic        op_valid, op_ready;
  logic [63:0] base_q, offset_q;
  logic [2:0]  opcode_q;
  logic        result_valid, result_bit, acc_error;
  logic        mem_valid, mem_write, mem_ready, mem_rvalid, mem_fault;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0]  mem_wstrb;

  bit_accelerator u_acc (
    .clk, .reset,
    .op_valid, .op_ready,
    .base_address(base_q), .bit_offset(offset_q), .operation(opcode_q),
    .result_valid, .result_bit, .error(acc_error),
    .mem_valid, .mem_write, .mem_addr, .mem_wdata, .mem_wstrb,
    .mem_ready, .mem_rvalid, .mem_rdata, .mem_fault);

  // ------------------------------------------------------------- memory
  logic          ram_we;
  logic [AW-1:0] ram_addr;
  logic [63:0]   ram_wdata, ram_rdata;

  word_memory #(.DEPTH(DEPTH)) u_ram (
    .clk, .we(ram_we), .addr(ram_addr), .wdata(ram_wdata), .rdata(ram_rdata));

  typedef enum logic [3:0] {
    S_CMD, S_ARGS, S_HOST_WRITE, S_HOST_READ, S_HOST_READ_DATA,
    S_LOAD, S_START, S_EXEC, S_SEND
  } state_t;
  state_t state;

  logic [7:0]    cmd;
  logic [4:0]    nargs, argi;       // argument bytes expected / received
  logic [7:0]    args [0:16];
  logic [7:0]    reply [0:7];
  logic [3:0]    nreply, replyi;
  logic          in_range;

  logic unused_ok;
  assign unused_ok = &{1'b0, mem_wstrb, mem_addr[2:0]};  // whole-word access, strobes all ones

  // The accelerator owns the RAM port only in S_EXEC; the host commands use it otherwise.
  assign in_range  = (mem_addr[63:AW+3] == '0);
  assign mem_ready = (state == S_EXEC);
  assign mem_rdata = ram_rdata;
  assign ram_we    = (state == S_EXEC) ? (mem_valid && mem_write && in_range)
                                       : (state == S_HOST_WRITE);
  assign ram_addr  = (state == S_EXEC) ? mem_addr[AW+2:3] : args[0][AW-1:0];
  assign ram_wdata = (state == S_EXEC) ? mem_wdata
                                       : {args[8], args[7], args[6], args[5],
                                          args[4], args[3], args[2], args[1]};
  assign op_valid  = (state == S_START);
  assign tx_data   = reply[replyi[2:0]];
  assign tx_start  = (state == S_SEND) && tx_ready && (replyi < nreply);
  assign led_busy  = (state == S_START) || (state == S_EXEC);

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_CMD; cmd <= '0; nargs <= '0; argi <= '0;
      nreply <= '0; replyi <= '0; led_error <= 1'b0;
      base_q <= '0; offset_q <= '0; opcode_q <= '0;
      mem_rvalid <= 1'b0; mem_fault <= 1'b0;
    end else begin
      mem_rvalid <= 1'b0;
      mem_fault  <= 1'b0;
      case (state)
        S_CMD: if (rx_valid) begin
          cmd <= rx_data; argi <= '0; replyi <= '0;
          case (rx_data)
            8'h50: begin reply[0] <= 8'h42; nreply <= 4'd1; state <= S_SEND; end  // 'P'
            8'h57: begin nargs <= 5'd9;  state <= S_ARGS; end                     // 'W'
            8'h52: begin nargs <= 5'd1;  state <= S_ARGS; end                     // 'R'
            8'h58: begin nargs <= 5'd17; state <= S_ARGS; end                     // 'X'
            default: begin reply[0] <= 8'h3F; nreply <= 4'd1; state <= S_SEND; end
          endcase
        end
        S_ARGS: if (rx_valid) begin
          args[argi] <= rx_data;
          argi <= argi + 1'b1;
          if (argi + 1'b1 == nargs) begin
            case (cmd)
              8'h57:   state <= S_HOST_WRITE;
              8'h52:   state <= S_HOST_READ;
              default: state <= S_LOAD;
            endcase
          end
        end
        S_HOST_WRITE: begin                      // ram_we is high this cycle
          reply[0] <= 8'h4B; nreply <= 4'd1; state <= S_SEND;
        end
        S_HOST_READ: state <= S_HOST_READ_DATA;  // address presented this cycle
        S_HOST_READ_DATA: begin
          for (int i = 0; i < 8; i++) reply[i] <= ram_rdata[8*i +: 8];
          nreply <= 4'd8; state <= S_SEND;
        end
        S_LOAD: begin                            // operands are stable before op_valid
          opcode_q <= args[0][2:0];
          base_q   <= {args[8],  args[7],  args[6],  args[5],  args[4],  args[3],  args[2],  args[1]};
          offset_q <= {args[16], args[15], args[14], args[13], args[12], args[11], args[10], args[9]};
          state <= S_START;
        end
        S_START: if (op_ready) state <= S_EXEC;  // op_valid is high in S_START
        S_EXEC: begin
          // Memory slave: always ready, one-cycle read latency, fault out of range.
          if (mem_valid && !mem_write) begin
            if (in_range) mem_rvalid <= 1'b1; else mem_fault <= 1'b1;
          end
          // Unreachable here (a write always follows a successful read of the same
          // word) but kept so the slave honours the interface contract.
          if (mem_valid && mem_write && !in_range) mem_fault <= 1'b1;
          if (result_valid) begin
            reply[0] <= 8'hA0 | {6'd0, acc_error, result_bit};
            led_error <= acc_error;
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
endmodule
