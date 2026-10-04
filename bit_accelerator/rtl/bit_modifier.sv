// Bit Modifier - Set, clear, and toggle operations on a 64-bit word

module bit_modifier (
  input  logic [63:0] word_data,
  input  logic [5:0]  bit_index,
  input  logic [2:0]  operation,  // SET=3'b010, CLEAR=3'b011, TOGGLE=3'b100

  output logic [63:0] result
);

  logic [63:0] bit_mask;

  // Generate mask with single bit set at bit_index
  // For bit_index=0: mask = 64'h0000_0000_0000_0001
  // For bit_index=63: mask = 64'h8000_0000_0000_0000

  assign bit_mask = 64'h1 << bit_index;

  // Apply operation
  always_comb begin
    case (operation)
      3'b010:  result = word_data | bit_mask;   // BIT_SET
      3'b011:  result = word_data & ~bit_mask;  // BIT_CLEAR
      3'b100:  result = word_data ^ bit_mask;   // BIT_TOGGLE
      default: result = word_data;               // No-op
    endcase
  end

endmodule : bit_modifier
