// Bit-string accelerator: one GET/TEST/SET/CLEAR/TOGGLE per operation on a
// 64-bit-word memory. See docs/verification.md for the interface contract.
//
//   effective_bit = (base_address << 3) + bit_offset      (mod 2^64)
//   mem_addr      = (effective_bit >> 6) << 3              (8-byte aligned)
//   bit index     = effective_bit[5:0]                     (LSB-first)
//
// result_valid is a one-cycle pulse; error and result_bit are valid in that
// same cycle. On error, result_bit holds its previous value.
module bit_accelerator #(
  parameter int ADDR_W=64,
  parameter int WORD_W=64
)(
  input logic clk,input logic reset,
  input logic op_valid, output logic op_ready,
  input logic [ADDR_W-1:0] base_address,
  input logic [63:0] bit_offset,
  input logic [2:0] operation,
  output logic result_valid, output logic result_bit, output logic error,
  output logic mem_valid, output logic mem_write,
  output logic [ADDR_W-1:0] mem_addr,
  output logic [WORD_W-1:0] mem_wdata,
  output logic [WORD_W/8-1:0] mem_wstrb,
  input logic mem_ready, input logic mem_rvalid,
  input logic [WORD_W-1:0] mem_rdata, input logic mem_fault
);
  localparam logic [2:0] OP_GET=3'b000, OP_TEST=3'b001, OP_SET=3'b010,
                         OP_CLEAR=3'b011, OP_TOGGLE=3'b100;
  typedef enum logic [2:0] {IDLE,READ_REQ,READ_WAIT,WRITE_REQ,WRITE_WAIT,RESP} state_t;
  state_t state;
  logic [ADDR_W-1:0] req_addr;
  logic [63:0] eff_bit;
  logic [5:0] bit_idx_q;
  logic err_q;          // error latched during the operation, reported with result_valid
  logic [2:0] op_q;
  logic old_bit_q;
  logic [WORD_W-1:0] new_word_q;
  logic [WORD_W-1:0] shifted_one;

  assign op_ready = (state == IDLE) && !reset;
  assign mem_valid = (state == READ_REQ || state == WRITE_REQ);
  assign mem_write = (state == WRITE_REQ);
  assign mem_addr = req_addr;
  assign mem_wdata = new_word_q;
  assign mem_wstrb = {WORD_W/8{1'b1}};
  assign shifted_one = ({{(WORD_W-1){1'b0}},1'b1} << bit_idx_q);
  assign eff_bit = (64'(base_address) << 3) + bit_offset;

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= IDLE; result_valid <= 1'b0; result_bit <= 1'b0; error <= 1'b0;
      req_addr <= '0; bit_idx_q <= '0; err_q <= 1'b0;
      op_q <= OP_GET; old_bit_q <= 1'b0; new_word_q <= '0;
    end else begin
      result_valid <= 1'b0; error <= 1'b0;
      case (state)
        IDLE: if (op_valid) begin
          op_q <= operation;
          err_q <= 1'b0;
          bit_idx_q <= eff_bit[5:0];
          req_addr <= ADDR_W'((eff_bit >> 6) << 3);
          state <= READ_REQ;
        end
        READ_REQ: if (mem_ready) state <= READ_WAIT;
        READ_WAIT: if (mem_fault) begin err_q <= 1'b1; state <= RESP; end
          else if (mem_rvalid) begin
            old_bit_q <= mem_rdata[bit_idx_q];
            case (op_q)
              OP_GET, OP_TEST: state <= RESP;
              OP_SET: begin new_word_q <= mem_rdata | shifted_one; state <= WRITE_REQ; end
              OP_CLEAR: begin new_word_q <= mem_rdata & ~shifted_one; state <= WRITE_REQ; end
              OP_TOGGLE: begin new_word_q <= mem_rdata ^ shifted_one; state <= WRITE_REQ; end
              default: begin err_q <= 1'b1; state <= RESP; end
            endcase
          end
        WRITE_REQ: if (mem_ready) state <= WRITE_WAIT;
        WRITE_WAIT: begin
          if (mem_fault) err_q <= 1'b1;
          state <= RESP;
        end
        RESP: begin
          result_valid <= 1'b1;
          error <= err_q;
          if (!err_q) begin
            case (op_q)
              OP_GET, OP_TEST: result_bit <= old_bit_q;
              OP_SET: result_bit <= 1'b1;
              OP_CLEAR: result_bit <= 1'b0;
              OP_TOGGLE: result_bit <= ~old_bit_q;
              default: result_bit <= 1'b0;
            endcase
          end
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
