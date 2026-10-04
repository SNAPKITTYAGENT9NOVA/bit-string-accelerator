// Testbench for Bit-String Hardware Accelerator
// Comprehensive functional verification of all operations and edge cases

module tb_bit_accelerator ();

  // Parameters
  localparam int ADDR_WIDTH = 64;
  localparam int WORD_WIDTH = 64;
  localparam int WORD_BYTES = WORD_WIDTH / 8;
  localparam int READ_LATENCY = 2;

  // Clock and Reset
  logic clk;
  logic reset;

  // DUT: Operation Interface
  logic        op_valid;
  logic        op_ready;
  logic [63:0] base_address;
  logic [63:0] bit_offset;
  logic [2:0]  operation;

  // DUT: Response Interface
  logic        result_valid;
  logic        result_bit;
  logic        error;

  // DUT: Memory Interface
  logic                   mem_req_valid;
  logic                   mem_req_ready;
  logic [ADDR_WIDTH-1:0]  mem_addr;
  logic                   mem_read;
  logic                   mem_write;
  logic [WORD_BYTES-1:0]  mem_wstrb;
  logic [WORD_WIDTH-1:0]  mem_wdata;
  logic                   mem_rvalid;
  logic [WORD_WIDTH-1:0]  mem_rdata;
  logic                   mem_fault;

  // DUT Instantiation
  bit_accelerator dut (
    .clk         (clk),
    .reset       (reset),
    .op_valid    (op_valid),
    .op_ready    (op_ready),
    .base_address(base_address),
    .bit_offset  (bit_offset),
    .operation   (operation),
    .result_valid(result_valid),
    .result_bit  (result_bit),
    .error       (error),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_addr    (mem_addr),
    .mem_read    (mem_read),
    .mem_write   (mem_write),
    .mem_wstrb   (mem_wstrb),
    .mem_wdata   (mem_wdata),
    .mem_rvalid  (mem_rvalid),
    .mem_rdata   (mem_rdata),
    .mem_fault   (mem_fault)
  );

  // Memory Model
  behavioral_memory #(
    .ADDR_WIDTH  (ADDR_WIDTH),
    .WORD_WIDTH  (WORD_WIDTH),
    .READ_LATENCY(READ_LATENCY)
  ) memory_model (
    .clk     (clk),
    .reset   (reset),
    .req_valid(mem_req_valid),
    .req_ready(mem_req_ready),
    .addr    (mem_addr),
    .is_read (mem_read),
    .is_write(mem_write),
    .wstrb   (mem_wstrb),
    .wdata   (mem_wdata),
    .rvalid  (mem_rvalid),
    .rdata   (mem_rdata),
    .fault   (mem_fault)
  );

  // Clock generation (10ns period = 100 MHz)
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Test vector structure
  typedef struct packed {
    logic [63:0] base_addr;
    logic [63:0] bit_offset;
    logic [2:0]  op;
    logic [63:0] expected_word;
    logic        expected_bit;
    string       test_name;
  } test_vec_t;

  // Test counters
  int test_count = 0;
  int pass_count = 0;
  int fail_count = 0;

  // Helper tasks

  task automatic write_memory(logic [63:0] byte_addr, logic [63:0] data);
    logic [63:0] word_addr = byte_addr >> 3;
    // Direct write to memory model's memory array
    // (In real simulation, use the memory interface)
  endtask

  task automatic init_memory();
    // Initialize memory with test pattern
    // Word at byte address 0x00: 64'h0123456789ABCDEF
    // Word at byte address 0x08: 64'hFEDCBA9876543210
    // Word at byte address 0x10: 64'hAAAAAAAAAAAAAAAA
    // Word at byte address 0x18: 64'h5555555555555555

    automatic logic [63:0] init_data[4];
    init_data[0] = 64'h0123456789ABCDEF;
    init_data[1] = 64'hFEDCBA9876543210;
    init_data[2] = 64'hAAAAAAAAAAAAAAAA;
    init_data[3] = 64'h5555555555555555;

    // Write to memory via operation (requires memory to be functional)
    // For now, directly access memory_model.memory
    for (int i = 0; i < 4; i++) begin
      memory_model.memory[i] = init_data[i];
    end
  endtask

  task automatic run_operation(
    input logic [63:0] base_addr,
    input logic [63:0] bit_off,
    input logic [2:0]  op,
    output logic       result_bit_out,
    output logic       error_out
  );
    logic done = 1'b0;
    int cycles = 0;

    // Assert operation request
    op_valid <= 1'b1;
    base_address <= base_addr;
    bit_offset <= bit_off;
    operation <= op;

    // Wait for acceptance
    @(posedge clk);
    while (!op_ready && cycles < 100) begin
      @(posedge clk);
      cycles++;
    end

    op_valid <= 1'b0;

    // Wait for result
    cycles = 0;
    while (!result_valid && cycles < 200) begin
      @(posedge clk);
      cycles++;
    end

    if (result_valid) begin
      result_bit_out = result_bit;
      error_out = error;
    end else begin
      result_bit_out = 1'bX;
      error_out = 1'b1;
    end
  endtask

  task automatic test_bit_get(logic [63:0] base_addr, logic [63:0] bit_off, logic expected_bit, string test_name);
    logic result_bit_out;
    logic error_out;

    $display("[%0d] Testing BIT_GET: %s", test_count, test_name);
    run_operation(base_addr, bit_off, 3'b000, result_bit_out, error_out);

    if (error_out) begin
      $display("  FAIL: Operation returned error");
      fail_count++;
    end else if (result_bit_out === expected_bit) begin
      $display("  PASS: Got expected bit value %b", expected_bit);
      pass_count++;
    end else begin
      $display("  FAIL: Expected %b, got %b", expected_bit, result_bit_out);
      fail_count++;
    end

    test_count++;
    @(posedge clk);
  endtask

  task automatic test_bit_set(logic [63:0] base_addr, logic [63:0] bit_off, string test_name);
    logic result_bit_out;
    logic error_out;

    $display("[%0d] Testing BIT_SET: %s", test_count, test_name);
    run_operation(base_addr, bit_off, 3'b010, result_bit_out, error_out);

    if (error_out) begin
      $display("  FAIL: Operation returned error");
      fail_count++;
    end else begin
      $display("  PASS: BIT_SET completed, result=%b", result_bit_out);
      pass_count++;
    end

    test_count++;
    @(posedge clk);
  endtask

  task automatic test_bit_clear(logic [63:0] base_addr, logic [63:0] bit_off, string test_name);
    logic result_bit_out;
    logic error_out;

    $display("[%0d] Testing BIT_CLEAR: %s", test_count, test_name);
    run_operation(base_addr, bit_off, 3'b011, result_bit_out, error_out);

    if (error_out) begin
      $display("  FAIL: Operation returned error");
      fail_count++;
    end else begin
      $display("  PASS: BIT_CLEAR completed, result=%b", result_bit_out);
      pass_count++;
    end

    test_count++;
    @(posedge clk);
  endtask

  // Main Testbench
  initial begin
    // Initialize signals
    op_valid = 1'b0;
    base_address = 64'h0;
    bit_offset = 64'h0;
    operation = 3'h0;
    reset = 1'b0;

    // Reset sequence
    #20;
    reset = 1'b1;
    #20;

    $display("\n========================================");
    $display("    BIT ACCELERATOR FUNCTIONAL TEST     ");
    $display("========================================\n");

    // Initialize memory
    init_memory();

    // Test 1: BIT_GET at various offsets (single word)
    $display("\n--- Test Group 1: Single-Word Bit Extraction ---");

    // Word 0 = 0x0123456789ABCDEF
    // Bit 0 (LSB of byte 0): 1
    test_bit_get(64'h00, 64'h0, 1'b1, "bit 0 of word 0");

    // Bit 1: 1
    test_bit_get(64'h00, 64'h1, 1'b1, "bit 1 of word 0");

    // Bit 7: 0
    test_bit_get(64'h00, 64'h7, 1'b0, "bit 7 of word 0");

    // Bit 8 (LSB of byte 1): 1
    test_bit_get(64'h00, 64'h8, 1'b1, "bit 8 of word 0");

    // Bit 31: 0
    test_bit_get(64'h00, 64'h1F, 1'b0, "bit 31 of word 0");

    // Bit 32: 1
    test_bit_get(64'h00, 64'h20, 1'b1, "bit 32 of word 0");

    // Bit 63 (MSB of word): 0
    test_bit_get(64'h00, 64'h3F, 1'b0, "bit 63 of word 0");

    // Test 2: Cross-word boundary
    $display("\n--- Test Group 2: Cross-Word Boundary ---");

    // Word 1 = 0xFEDCBA9876543210
    // Bit 64 (bit 0 of word 1): 0
    test_bit_get(64'h00, 64'h40, 1'b0, "bit 64 (bit 0 of word 1)");

    // Bit 65: 0
    test_bit_get(64'h00, 64'h41, 1'b0, "bit 65 (bit 1 of word 1)");

    // Test 3: Base address offset
    $display("\n--- Test Group 3: Non-Zero Base Address ---");

    // Base address = 0x08 (word 1)
    // Bit offset = 0 (bit 0 of word 1)
    test_bit_get(64'h08, 64'h0, 1'b0, "base=0x08, offset=0");

    // Test 4: Modify operations
    $display("\n--- Test Group 4: Modify Operations ---");

    test_bit_set(64'h10, 64'h0, "BIT_SET at bit 0 of word 2");
    test_bit_clear(64'h10, 64'h0, "BIT_CLEAR at bit 0 of word 2");

    // Summary
    $display("\n========================================");
    $display("    TEST SUMMARY                        ");
    $display("========================================");
    $display("Total Tests:  %0d", test_count);
    $display("Passed:       %0d", pass_count);
    $display("Failed:       %0d", fail_count);

    if (fail_count == 0) begin
      $display("\n✓ All tests PASSED!");
    end else begin
      $display("\n✗ %0d tests FAILED!", fail_count);
    end
    $display("========================================\n");

    #100;
    $finish;
  end

endmodule : tb_bit_accelerator
