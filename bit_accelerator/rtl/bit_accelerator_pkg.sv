// Bit Accelerator Package - Type Definitions and Constants

package bit_accelerator_pkg;

  // Opcode Definitions
  typedef enum logic [5:0] {
    BITLOAD      = 6'h01,
    BITSTORE     = 6'h02,
    BITFIELD     = 6'h03,
    BITTEST      = 6'h04,
    BITCOUNT     = 6'h05,
    BITSCANFWD   = 6'h06,
    BITSCANREV   = 6'h07,
    LOADIMM64    = 6'h08,
    BITEXTRACT   = 6'h09,
    BITINSERT    = 6'h0A,
    BITROTL      = 6'h0B,
    BITROTR      = 6'h0C
  } opcode_t;

  // Register Specifier (5 bits)
  typedef logic [4:0] reg_addr_t;

  // Immediate Values
  typedef logic [17:0] imm18_t;
  typedef logic [52:0] imm53_t;

  // 64-bit Word/Address
  typedef logic [63:0] word64_t;

  // Bit Index (0-63)
  typedef logic [5:0] bit_idx_t;

  // Word Index (for 64-bit memory word, within addressable space)
  typedef logic [57:0] word_idx_t;

  // Effective Bit Address
  typedef logic [63:0] eff_addr_t;

  // Instruction Format
  typedef struct packed {
    opcode_t opcode;    // [5:0]
    reg_addr_t rd;      // [10:6]
    reg_addr_t rs1;     // [15:11]
    reg_addr_t rs2;     // [20:16]
    logic [43:0] unused; // [63:21]
  } instr_r_t;

  typedef struct packed {
    opcode_t opcode;    // [5:0]
    reg_addr_t rd;      // [10:6]
    reg_addr_t rs1;     // [15:11]
    imm18_t imm;        // [33:16]
    logic [29:0] unused; // [63:34]
  } instr_i_t;

  typedef struct packed {
    opcode_t opcode;    // [5:0]
    reg_addr_t rd;      // [10:6]
    imm53_t imm;        // [58:11]
    logic [4:0] unused; // [63:59]
  } instr_l_t;

  // Control Signals
  typedef struct packed {
    logic enable_addr_gen;
    logic enable_mem_load;
    logic enable_mem_store;
    logic enable_shift;
    logic enable_extract;
    logic enable_writeback;
    logic shift_direction;  // 0=right, 1=left
    logic rotate_mode;      // 0=shift, 1=rotate
    logic is_signed;
    bit_idx_t field_width;
  } ctrl_signals_t;

  // Exception Codes
  typedef enum logic [3:0] {
    EXC_NONE           = 4'h0,
    EXC_PAGE_FAULT     = 4'h1,
    EXC_PROTECTION     = 4'h2,
    EXC_INVALID_ADDR   = 4'h3,
    EXC_INVALID_WIDTH  = 4'h4
  } exception_t;

  // Pipeline Stage Signals
  typedef struct packed {
    opcode_t opcode;
    reg_addr_t rd;
    word64_t rs1_data;
    word64_t rs2_data;
    word64_t rs3_data;
    ctrl_signals_t ctrl;
    exception_t exc;
  } stage_s1_t;

  typedef struct packed {
    opcode_t opcode;
    reg_addr_t rd;
    word64_t rs3_data;
    eff_addr_t eff_addr;
    ctrl_signals_t ctrl;
    exception_t exc;
  } stage_s2_t;

  typedef struct packed {
    opcode_t opcode;
    reg_addr_t rd;
    word64_t rs3_data;
    word_idx_t word_idx;
    bit_idx_t bit_idx;
    ctrl_signals_t ctrl;
    exception_t exc;
  } stage_s3_t;

  typedef struct packed {
    opcode_t opcode;
    reg_addr_t rd;
    word64_t memory_word;
    bit_idx_t bit_idx;
    ctrl_signals_t ctrl;
    exception_t exc;
  } stage_s4_t;

  typedef struct packed {
    opcode_t opcode;
    reg_addr_t rd;
    word64_t extracted_value;
    exception_t exc;
  } stage_s5_t;

  // Control Status Register
  typedef struct packed {
    logic zf;               // Zero flag (from BITTEST)
    logic cf;               // Carry flag (unused)
    logic [61:0] reserved;
  } csr_t;

endpackage : bit_accelerator_pkg
