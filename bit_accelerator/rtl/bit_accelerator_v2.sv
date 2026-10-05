// Bit-String Hardware Accelerator v2
// Corrected implementation with explicit write completion semantics
// Reset and in-flight operation cancellation

module bit_accelerator_v2 #(
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

  // Result Interface (one-cycle pulse)
  output logic                         result_valid,
  output logic                         result_bit,
  output logic                         error,

  // Memory Interface (AXI-like handshaking)
  output logic                         mem_valid,      // Read or write valid
  output logic                         mem_write,      // 0=read, 1=write
  output logic [ADDR_WIDTH-1:0]        mem_addr,       // Byte address (8-byte aligned)
  output logic [WORD_WIDTH-1:0]        mem_wdata,      // Write data
  output logic [WORD_BYTES-1:0]        mem_wstrb,      // Write strobes
  input  logic                         mem_ready,      // Ready to accept

  input  logic                         mem_rvalid,     // Read valid
  input  logic [WORD_WIDTH-1:0]        mem_rdata,      // Read data
  input  logic                         mem_fault       // Read fault
);

  // ===== State Machine =====
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_READ_REQUEST,
    ST_READ_WAIT,
    ST_MODIFY,
    ST_WRITE_REQUEST,
    ST_WRITE_WAIT,
    ST_RESULT
  } state_t;

  state_t current_state, next_state;

  // ===== Stored Operation State =====
  logic [63:0] base_addr_reg, bit_offset_reg;
  logic [2:0]  operation_reg;
  logic        is_modify_op;

  // ===== Calculated Address Components =====
  logic [63:0] absolute_bit_address;
  logic [57:0] word_address;
  logic [5:0]  bit_index_in_word;

  // ===== Data Path =====
  logic [63:0] read_word;
  logic [63:0] modified_word;
  logic        result_data;

  // ===== Address Calculation (Combinational) =====
  assign absolute_bit_address = (base_addr_reg << 3) + bit_offset_reg;
  assign word_address = absolute_bit_address[63:6];
  assign bit_index_in_word = absolute_bit_address[5:0];
  assign mem_addr = ADDR_WIDTH'({word_address, 3'b000});  // word address -> byte address (zero-extended)

  // Check if operation is a modify operation
  assign is_modify_op = (operation_reg == 3'b010) ||  // SET
                        (operation_reg == 3'b011) ||  // CLEAR
                        (operation_reg == 3'b100);    // TOGGLE


  // ===== Bit Modification =====
  always_comb begin
    case (operation_reg)
      3'b010:  modified_word = read_word | (64'h1 << bit_index_in_word);   // SET
      3'b011:  modified_word = read_word & ~(64'h1 << bit_index_in_word);  // CLEAR
      3'b100:  modified_word = read_word ^ (64'h1 << bit_index_in_word);   // TOGGLE
      default: modified_word = read_word;
    endcase
  end

  // ===== Result Extraction =====
  assign result_data = read_word[bit_index_in_word];  // bit extraction

  // Result is a one-cycle pulse, combinational from ST_RESULT
  assign result_valid = (current_state == ST_RESULT);
  assign result_bit   = (current_state == ST_RESULT) ? result_data : 1'b0;

  // ===== State Machine: Sequential =====
  always_ff @(posedge clk) begin
    if (reset) begin
      current_state <= ST_IDLE;
      base_addr_reg <= 64'h0;
      bit_offset_reg <= 64'h0;
      operation_reg <= 3'h0;
      read_word <= 64'h0;
      error <= 1'b0;
    end else begin
      current_state <= next_state;

      // Capture operation on acceptance
      if (op_valid && op_ready) begin
        base_addr_reg <= base_address;
        bit_offset_reg <= bit_offset;
        operation_reg <= operation;
      end

      // Capture read data
      if (mem_rvalid && current_state == ST_READ_WAIT) begin
        read_word <= mem_rdata;
      end

      // Error status: cleared on accept, set on read fault while waiting
      if (op_valid && op_ready) begin
        error <= 1'b0;
      end else if (mem_fault && current_state == ST_READ_WAIT) begin
        error <= 1'b1;
      end
    end
  end

  // ===== State Machine: Combinational Next-State Logic =====
  always_comb begin
    next_state = current_state;
    op_ready = 1'b0;
    mem_valid = 1'b0;
    mem_write = 1'b0;
    mem_wdata = 64'h0;
    mem_wstrb = 8'h00;

    case (current_state)
      ST_IDLE: begin
        op_ready = 1'b1;
        if (op_valid) begin
          next_state = ST_READ_REQUEST;
        end
      end

      ST_READ_REQUEST: begin
        mem_valid = 1'b1;
        mem_write = 1'b0;
        if (mem_ready) begin
          next_state = ST_READ_WAIT;
        end
        // else stay in READ_REQUEST (stall)
      end

      ST_READ_WAIT: begin
        if (mem_rvalid) begin
          if (is_modify_op) begin
            next_state = ST_MODIFY;
          end else begin
            // BIT_GET or BIT_TEST: go directly to result
            next_state = ST_RESULT;
          end
        end
        if (mem_fault) begin
          next_state = ST_RESULT;
        end
      end

      ST_MODIFY: begin
        // One cycle to calculate modified value
        next_state = ST_WRITE_REQUEST;
      end

      ST_WRITE_REQUEST: begin
        mem_valid = 1'b1;
        mem_write = 1'b1;
        mem_wdata = modified_word;
        mem_wstrb = 8'hFF;  // All bytes
        if (mem_ready) begin
          next_state = ST_WRITE_WAIT;
        end
        // else stay in WRITE_REQUEST (stall)
      end

      ST_WRITE_WAIT: begin
        // Write accepted, no separate write-response in this model
        // Go to result state
        next_state = ST_RESULT;
      end

      ST_RESULT: begin
        // result_valid asserted this cycle
        // Next cycle return to IDLE
        next_state = ST_IDLE;
      end

      default: next_state = ST_IDLE;
    endcase

    // A request presented in a cycle where reset is asserted is never issued,
    // so reset cannot race with a write handshake at the same clock edge.
    if (reset) begin
      mem_valid = 1'b0;
      mem_write = 1'b0;
      mem_wdata = 64'h0;
      mem_wstrb = 8'h00;
    end
  end

endmodule : bit_accelerator_v2
