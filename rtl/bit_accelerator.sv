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
  logic [ADDR_W-1:0] req_addr, base_q;
  logic [63:0] off_q, abs_bit_q;
  logic [5:0] bit_idx_q;
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

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= IDLE; result_valid <= 1'b0; result_bit <= 1'b0; error <= 1'b0;
      req_addr <= '0; base_q <= '0; off_q <= '0; abs_bit_q <= '0; bit_idx_q <= '0;
      op_q <= OP_GET; old_bit_q <= 1'b0; new_word_q <= '0;
    end else begin
      result_valid <= 1'b0; error <= 1'b0;
      case (state)
        IDLE: if (op_valid) begin
          base_q <= base_address; off_q <= bit_offset; op_q <= operation;
          abs_bit_q <= (base_address << 3) + bit_offset;
          bit_idx_q <= ((base_address << 3) + bit_offset)[5:0];
          req_addr <= ((((base_address << 3) + bit_offset) >> 6) << 3);
          state <= READ_REQ;
        end
        READ_REQ: if (mem_ready) state <= READ_WAIT;
        READ_WAIT: if (mem_fault) begin error <= 1'b1; state <= RESP; end
          else if (mem_rvalid) begin
            old_bit_q <= mem_rdata[bit_idx_q];
            case (op_q)
              OP_GET, OP_TEST: state <= RESP;
              OP_SET: begin new_word_q <= mem_rdata | shifted_one; state <= WRITE_REQ; end
              OP_CLEAR: begin new_word_q <= mem_rdata & ~shifted_one; state <= WRITE_REQ; end
              OP_TOGGLE: begin new_word_q <= mem_rdata ^ shifted_one; state <= WRITE_REQ; end
              default: begin error <= 1'b1; state <= RESP; end
            endcase
          end
        WRITE_REQ: if (mem_ready) state <= WRITE_WAIT;
        WRITE_WAIT: begin
          if (mem_fault) error <= 1'b1;
          state <= RESP;
        end
        RESP: begin
          result_valid <= 1'b1;
          if (!error) begin
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
