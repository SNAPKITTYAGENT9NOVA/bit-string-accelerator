module tb_bit_accelerator;
  logic clk=0,reset=1,op_valid,op_ready; logic [63:0] base_address,bit_offset;
  logic [2:0] operation; logic result_valid,result_bit,error;
  logic mem_valid,mem_write,mem_ready,mem_rvalid,mem_fault;
  logic [63:0] mem_addr,mem_wdata,mem_rdata; logic [7:0] mem_wstrb;
  logic [63:0] mem[0:31]; integer i;
  bit pending_read; integer delay;
  bit pending_write;
  bit_accelerator dut(.*);
  always #5 clk=~clk;
  always_ff @(posedge clk) begin
    mem_ready <= 1'b1; mem_rvalid <= 1'b0; mem_fault <= 1'b0;
    if (mem_valid && !mem_write && mem_ready) begin pending_read<=1; delay<=1; end
    if (pending_read) begin if(delay==0) begin mem_rdata<=mem[mem_addr>>3]; mem_rvalid<=1; pending_read<=0; end else delay<=delay-1; end
    if (mem_valid && mem_write && mem_ready) begin mem[mem_addr>>3]<=mem_wdata; pending_write<=1; end
    if (pending_write) pending_write<=0;
  end
  task automatic run(input [63:0] off,input [2:0] op,input expected);
    @(negedge clk); base_address=0; bit_offset=off; operation=op; op_valid=1;
    @(negedge clk); op_valid=0; wait(result_valid); assert(result_bit===expected) else $fatal("offset %0d expected %0d got %0d",off,expected,result_bit);
  endtask
  initial begin
    op_valid=0;base_address=0;bit_offset=0;operation=0;mem_ready=0;mem_rvalid=0;mem_fault=0;pending_read=0;pending_write=0;delay=0;
    mem[0]=64'h8000000000000001; for(i=1;i<32;i=i+1) mem[i]=64'd0;
    repeat(2) @(posedge clk); reset<=0;
    run(0,3'b000,1); run(63,3'b000,1); run(64,3'b000,0); run(7,3'b001,0);
    run(1,3'b010,1); run(1,3'b001,1); run(1,3'b011,0); run(1,3'b100,1);
    @(posedge clk); $display("PASS: bit accelerator directed tests"); $finish;
  end
endmodule
