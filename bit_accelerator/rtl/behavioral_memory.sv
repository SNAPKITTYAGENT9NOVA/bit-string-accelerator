// Behavioral Memory Model for Simulation
// Provides a simple synchronous memory with configurable read latency

module behavioral_memory #(
  parameter int ADDR_WIDTH = 64,
  parameter int WORD_WIDTH = 64,
  parameter int WORD_BYTES = WORD_WIDTH / 8,
  parameter int READ_LATENCY = 2,
  parameter string INIT_FILE = ""
) (
  input  logic                         clk,
  input  logic                         reset,

  // Memory Request Interface
  input  logic                         req_valid,
  output logic                         req_ready,
  input  logic [ADDR_WIDTH-1:0]        addr,
  input  logic                         is_read,
  input  logic                         is_write,
  input  logic [WORD_BYTES-1:0]        wstrb,
  input  logic [WORD_WIDTH-1:0]        wdata,

  // Memory Response Interface
  output logic                         rvalid,
  output logic [WORD_WIDTH-1:0]        rdata,
  output logic                         fault
);

  // Memory array: 64K words (512KB total)
  logic [WORD_WIDTH-1:0] memory [0:65535];

  // Read pipeline for latency emulation
  logic [READ_LATENCY-1:0] read_valid_pipe;
  logic [WORD_WIDTH-1:0] read_data_pipe [0:READ_LATENCY-1];
  logic [ADDR_WIDTH-1:0] read_addr_pipe [0:READ_LATENCY-1];

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, memory);
    end else begin
      for (int i = 0; i < 65536; i++) begin
        memory[i] = 64'h0;
      end
    end
  end

  // Request handling
  always_ff @(posedge clk or negedge reset) begin
    if (!reset) begin
      req_ready <= 1'b1;
      rvalid <= 1'b0;
      rdata <= 64'h0;
      fault <= 1'b0;
      for (int i = 0; i < READ_LATENCY; i++) begin
        read_valid_pipe[i] <= 1'b0;
        read_data_pipe[i] <= 64'h0;
      end
    end else begin
      // Always ready to accept requests
      req_ready <= 1'b1;

      // Handle write operations immediately
      if (req_valid && is_write) begin
        // Word-aligned write at address / 8
        logic [ADDR_WIDTH-1:0] word_addr = addr >> 3;
        if (word_addr < 65536) begin
          // Apply write strobes (byte enables)
          for (int i = 0; i < WORD_BYTES; i++) begin
            if (wstrb[i]) begin
              memory[word_addr][i*8 +: 8] <= wdata[i*8 +: 8];
            end
          end
        end
      end

      // Handle read operations (pipeline)
      read_valid_pipe[0] <= req_valid && is_read;
      if (req_valid && is_read) begin
        logic [ADDR_WIDTH-1:0] word_addr = addr >> 3;
        read_addr_pipe[0] <= word_addr;
        if (word_addr < 65536) begin
          read_data_pipe[0] <= memory[word_addr];
        end else begin
          read_data_pipe[0] <= 64'hDEADBEEFDEADBEEF;  // Fault marker
        end
      end

      // Pipeline shift for READ_LATENCY cycles
      for (int i = 1; i < READ_LATENCY; i++) begin
        read_valid_pipe[i] <= read_valid_pipe[i-1];
        read_data_pipe[i] <= read_data_pipe[i-1];
        read_addr_pipe[i] <= read_addr_pipe[i-1];
      end

      // Output from pipeline
      rvalid <= read_valid_pipe[READ_LATENCY-1];
      rdata <= read_data_pipe[READ_LATENCY-1];
      fault <= 1'b0;  // No faults in this simple model
    end
  end

endmodule : behavioral_memory
