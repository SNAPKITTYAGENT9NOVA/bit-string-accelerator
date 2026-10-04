// Bit Extractor - Single-bit and multi-bit extraction from a 64-bit word

module bit_extractor (
  input  logic [63:0] word_data,
  input  logic [5:0]  bit_index,
  input  logic [5:0]  field_width,  // For multi-bit extraction (1-64)
  input  logic        is_multibit,

  output logic [63:0] result
);

  logic [63:0] shifted_word;
  logic [63:0] mask;

  // Barrel shifter: rotate right by bit_index positions
  // This is combinational and synthesizes to mux tree
  assign shifted_word = word_data >> bit_index;

  // Generate mask for field width
  // For width=1: mask = 64'h0000_0000_0000_0001
  // For width=2: mask = 64'h0000_0000_0000_0003
  // For width=64: mask = 64'hFFFF_FFFF_FFFF_FFFF

  always_comb begin
    if (field_width == 6'h0)
      mask = 64'h0;
    else if (field_width == 6'd64)
      mask = 64'hFFFFFFFFFFFFFFFF;
    else
      mask = (64'h1 << field_width) - 1'b1;
  end

  // Extract field
  assign result = is_multibit ? (shifted_word & mask) : {63'h0, shifted_word[0]};

endmodule : bit_extractor
