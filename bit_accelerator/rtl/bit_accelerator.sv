// Top-Level Bit-String Hardware Accelerator
// Implements: BIT_BASE + BIT_OFFSET addressing with atomic read-modify-write

module bit_accelerator #(
  parameter int ADDR_WIDTH = 64,
  parameter int WORD_WIDTH = 64,
  parameter int WORD_BYTES = WORD_WIDTH / 8
) (
  input  logic                         clk,
  input  logic                         reset,

  // Operation Interface
  input  logic                         op_valid,
  output logic                         op_ready,
  input  logic [63:0]                  base_address,
  input  logic [63:0]                  bit_offset,
  input  logic [2:0]                   operation,  // 3'b000=GET, 3'b001=TEST, 3'b010=SET, 3'b011=CLEAR, 3'b100=TOGGLE

  // Response Interface
  output logic                         result_valid,
  output logic                         result_bit,
  output logic                         error,

  // Memory Interface (AXI-like, word-addressed)
  output logic                         mem_req_valid,
  input  logic                         mem_req_ready,
  output logic [ADDR_WIDTH-1:0]        mem_addr,
  output logic                         mem_read,
  output logic                         mem_write,
  output logic [WORD_BYTES-1:0]        mem_wstrb,
  output logic [WORD_WIDTH-1:0]        mem_wdata,

  input  logic                         mem_rvalid,
  input  logic [WORD_WIDTH-1:0]        mem_rdata,
  input  logic                         mem_fault
);

  // ===== State Machine =====
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_READ_REQUEST,
    ST_READ_WAIT,
    ST_MODIFY,
    ST_WRITE_REQUEST,
    ST_WRITE_WAIT,
    ST_DONE
  } state_t;

  state_t current_state, next_state;

  // ===== Internal Registers =====
  logic [63:0] base_addr_reg, bit_offset_reg;
  logic [2:0]  operation_reg;
  logic [63:0] absolute_bit_address;
  logic [57:0] word_address;        // byte address / 8
  logic [5:0]  bit_index_in_word;   // bit position within 64-bit word
  logic [63:0] read_word;
  logic [63:0] modified_word;
  logic        is_modify_op;        // SET, CLEAR, TOGGLE

  // ===== Combinational: Address Calculation =====

  // absolute_bit_address = (base_address × 8) + bit_offset
  logic [127:0] temp_addr;
  assign temp_addr = {1'b0, base_addr_reg} * 8 + {1'b0, bit_offset_reg};

  // Truncate to 64-bit (overflow handling)
  assign absolute_bit_address = temp_addr[63:0];

  // word_address = absolute_bit_address / 64 (right-shift by 6)
  assign word_address = absolute_bit_address[63:6];

  // bit_index_in_word = absolute_bit_address % 64
  assign bit_index_in_word = absolute_bit_address[5:0];

  // Convert word address to byte address for memory interface
  // word_address is already in 64-bit word units, multiply by 8 for byte address
  assign mem_addr = {word_address, 3'b000};  // Shift left by 3 (multiply by 8)

  // Check if operation is a modify operation
  assign is_modify_op = (operation_reg == 3'b010) ||  // SET
                        (operation_reg == 3'b011) ||  // CLEAR
                        (operation_reg == 3'b100);    // TOGGLE

  // ===== Submodules =====

  bit_extractor bit_extractor_inst (
    .word_data    (read_word),
    .bit_index    (bit_index_in_word),
    .field_width  (6'h1),
    .is_multibit  (1'b0),
    .result       ()  // Not used directly, result_bit comes from shift+AND
  );

  bit_modifier bit_modifier_inst (
    .word_data    (read_word),
    .bit_index    (bit_index_in_word),
    .operation    (operation_reg),
    .result       (modified_word)
  );

  // ===== Result Extraction (Combinational) =====
  logic [63:0] shifted_for_result;
  assign shifted_for_result = read_word >> bit_index_in_word;

  // ===== State Machine: Sequential =====

  always_ff @(posedge clk or negedge reset) begin
    if (!reset) begin
      current_state <= ST_IDLE;
      base_addr_reg <= 64'h0;
      bit_offset_reg <= 64'h0;
      operation_reg <= 3'h0;
      read_word <= 64'h0;
      result_valid <= 1'b0;
      result_bit <= 1'b0;
      error <= 1'b0;
    end else begin
      current_state <= next_state;
      result_valid <= 1'b0;
      error <= 1'b0;

      if (op_valid && op_ready) begin
        base_addr_reg <= base_address;
        bit_offset_reg <= bit_offset;
        operation_reg <= operation;
      end

      if (mem_rvalid && current_state == ST_READ_WAIT) begin
        read_word <= mem_rdata;
      end

      if (mem_fault) begin
        error <= 1'b1;
        result_valid <= 1'b1;
      end
    end
  end

  // ===== State Machine: Combinational Next-State Logic =====

  always_comb begin
    next_state = current_state;
    op_ready = 1'b0;
    mem_req_valid = 1'b0;
    mem_read = 1'b0;
    mem_write = 1'b0;
    mem_wstrb = 8'h00;
    mem_wdata = 64'h0;

    case (current_state)
      ST_IDLE: begin
        op_ready = 1'b1;
        if (op_valid) begin
          next_state = ST_READ_REQUEST;
        end
      end

      ST_READ_REQUEST: begin
        mem_req_valid = 1'b1;
        mem_read = 1'b1;
        if (mem_req_ready) begin
          next_state = ST_READ_WAIT;
        end
      end

      ST_READ_WAIT: begin
        if (mem_rvalid) begin
          if (is_modify_op) begin
            next_state = ST_MODIFY;
          end else begin
            next_state = ST_DONE;
          end
        end
        if (mem_fault) begin
          next_state = ST_DONE;
        end
      end

      ST_MODIFY: begin
        next_state = ST_WRITE_REQUEST;
      end

      ST_WRITE_REQUEST: begin
        mem_req_valid = 1'b1;
        mem_write = 1'b1;
        mem_wstrb = 8'hFF;  // All 8 bytes of the 64-bit word
        mem_wdata = modified_word;
        if (mem_req_ready) begin
          next_state = ST_WRITE_WAIT;
        end
      end

      ST_WRITE_WAIT: begin
        // For write operations, we don't wait for a write response in this simple model
        // Assume write completes immediately after acceptance
        next_state = ST_DONE;
      end

      ST_DONE: begin
        result_valid = 1'b1;
        result_bit = shifted_for_result[0];
        next_state = ST_IDLE;
      end

      default: next_state = ST_IDLE;
    endcase
  end

endmodule : bit_accelerator
