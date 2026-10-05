// UART-level testbench: drives the serial line exactly as a host would and
// checks every reply against a reference model of the RAM and the accelerator.
// Exits non-zero on any failure.
//
// Default: fpga_top (256 words). With +define+TT_TOP it tests the Tiny Tapeout
// top tt_um_snapkittyagent9nova_bitacc (4 words, divisor from ui_in pins).
// +define+GATE_LEVEL instantiates a synthesized netlist without parameters.
`timescale 1ns/1ps
module tb_fpga_top;
`ifdef TT_TOP
  localparam int DEPTH = 4;
`ifdef TT_DEFAULT_BAUD
  localparam int CPB   = 104;    // divisor pins all low -> 104 clocks per bit
`else
  localparam int CPB   = 8;      // ui_in divisor d = 2 -> 4*d clocks per bit
`endif
`else
  localparam int DEPTH = 256;
  localparam int CPB   = 8;      // clocks per UART bit (small to keep simulation fast)
`endif

  logic clk = 1'b0, reset = 1'b1, uart_rx = 1'b1;
  logic uart_tx, led_busy, led_error;

`ifdef TT_TOP
  logic [7:0] uo_out, uio_out, uio_oe;
`ifdef TT_DEFAULT_BAUD
  logic [6:0] div = 7'd0;
`else
  logic [6:0] div = 7'(CPB / 4);
`endif
`ifdef GL_TEST
  supply1 vpwr;                 // the powered post-layout netlist has inout supply pins
  supply0 vgnd;
`endif
  tt_um_snapkittyagent9nova_bitacc dut (
`ifdef GL_TEST
    .VPWR(vpwr), .VGND(vgnd),
`endif
    .ui_in({div[6:3], uart_rx, div[2:0]}), .uo_out, .uio_in(8'h00), .uio_out, .uio_oe,
    .ena(1'b1), .clk, .rst_n(!reset));
  assign uart_tx   = uo_out[4];
  assign led_busy  = uo_out[0];
  assign led_error = uo_out[1];
`elsif GATE_LEVEL
  fpga_top dut (.*);            // synthesized netlist, built with CLKS_PER_BIT = 8
`else
  fpga_top #(.CLKS_PER_BIT(CPB), .DEPTH(DEPTH)) dut (.*);
`endif

  always #5 clk = ~clk;

  integer checks = 0, fails = 0;
  task automatic check(input bit cond, input string what);
    checks++;
    if (!cond) begin fails++; $display("FAIL @%0t: %s", $time, what); end
  endtask

  // ------------------------------------------------ receiver: tx line -> FIFO
  logic [7:0] rxq [0:1023];
  integer rxq_wr = 0, rxq_rd = 0;
  initial begin : receiver
    logic [7:0] b;
    forever begin
      @(negedge uart_tx);
      repeat (CPB / 2) @(posedge clk);
      if (uart_tx !== 1'b0) check(0, "false start bit on tx");
      else begin
        for (int i = 0; i < 8; i++) begin
          repeat (CPB) @(posedge clk);
          b[i] = uart_tx;
        end
        repeat (CPB) @(posedge clk);
        check(uart_tx === 1'b1, "tx stop bit");
        rxq[rxq_wr % 1024] = b;
        rxq_wr++;
      end
    end
  end

  // ------------------------------------------------ host side
  // Inputs change on the falling edge so no flip-flop samples them mid-update
  // (a reset released exactly on a rising edge is seen by some flip-flops of a
  // gate-level netlist and not by others).
  task automatic send_byte(input logic [7:0] b);
    @(negedge clk);
    uart_rx = 1'b0; repeat (CPB) @(negedge clk);
    for (int i = 0; i < 8; i++) begin uart_rx = b[i]; repeat (CPB) @(negedge clk); end
    uart_rx = 1'b1; repeat (CPB) @(negedge clk);
  endtask

  task automatic recv_byte(output logic [7:0] b, output bit ok);
    integer waited = 0;
    while (rxq_rd == rxq_wr && waited < 400 * CPB) begin @(posedge clk); waited++; end
    ok = (rxq_rd != rxq_wr);
    b = ok ? rxq[rxq_rd % 1024] : 8'hxx;
    if (ok) rxq_rd++;
    check(ok, "reply byte timeout");
  endtask

  task automatic send_u64(input logic [63:0] v);
    for (int i = 0; i < 8; i++) send_byte(v[8*i +: 8]);
  endtask

  // ------------------------------------------------ reference model
  logic [63:0] model [0:DEPTH-1];

  task automatic cmd_write(input logic [7:0] idx, input logic [63:0] v);
    logic [7:0] r; bit ok;
    send_byte("W"); send_byte(idx); send_u64(v);
    recv_byte(r, ok);
    check(r == "K", $sformatf("W %0d reply %h", idx, r));
    model[idx] = v;
  endtask

  task automatic cmd_read_check(input logic [7:0] idx);
    logic [7:0] r; logic [63:0] v; bit ok;
    send_byte("R"); send_byte(idx);
    for (int i = 0; i < 8; i++) begin recv_byte(r, ok); v[8*i +: 8] = r; end
    check(v === model[idx], $sformatf("R %0d = %h, expected %h", idx, v, model[idx]));
  endtask

  task automatic cmd_exec(input logic [2:0] op, input logic [63:0] base, input logic [63:0] off);
    logic [63:0] eb, addr, word, onehot;
    logic [5:0] bi;
    bit in_range, exp_err, exp_bit, ok;
    logic [7:0] r;
    eb = (base << 3) + off;
    addr = (eb >> 6) << 3;
    bi = eb[5:0];
    onehot = 64'd1 << bi;
    in_range = (addr >> 3) < DEPTH;
    word = in_range ? model[addr >> 3] : '0;
    exp_err = !in_range || op > 3'd4;
    exp_bit = 1'b0;
    if (!exp_err) begin
      case (op)
        3'd2: begin model[addr >> 3] = word | onehot;  exp_bit = 1'b1; end
        3'd3: begin model[addr >> 3] = word & ~onehot; exp_bit = 1'b0; end
        3'd4: begin model[addr >> 3] = word ^ onehot;  exp_bit = !word[bi]; end
        default: exp_bit = word[bi];
      endcase
    end
    send_byte("X"); send_byte({5'd0, op}); send_u64(base); send_u64(off);
    recv_byte(r, ok);
    check(r[7:2] == 6'b101000, $sformatf("X status tag %h", r));
    check(r[1] == exp_err, $sformatf("X op %0d base %h off %h: error %b expected %b", op, base, off, r[1], exp_err));
    if (!exp_err) check(r[0] == exp_bit, $sformatf("X op %0d base %h off %h: bit %b expected %b", op, base, off, r[0], exp_bit));
    check(led_error == exp_err, "led_error follows the last operation");
  endtask

  // ------------------------------------------------ stimulus
  integer seed = 5;
  logic [7:0] r; bit ok;
  logic [63:0] rb, ro;
  logic [2:0] rop;

  initial begin
`ifdef TT_TOP
    // ASIC flip-flops have no power-up value; TX must be high while in reset.
    repeat (2) @(negedge clk);
    check(uart_tx === 1'b1, "tx high during reset");
    repeat (3) @(negedge clk);
`elsif GATE_LEVEL
    // FPGA netlist: flip-flops power up low (the cell models encode this), so TX
    // must idle high from power-up, before any reset edge; a low line here is a
    // start bit, i.e. a junk byte, to the host.
    #1 check(uart_tx === 1'b1, "tx idle-high at power-up");
    repeat (5) @(negedge clk);
`else
    // RTL has no power-up value (X); TX must be high while in reset. The
    // power-up property is checked on the gate-level netlists.
    repeat (2) @(negedge clk);
    check(uart_tx === 1'b1, "tx high during reset");
    repeat (3) @(negedge clk);
`endif
    reset = 1'b0;
    repeat (5) @(negedge clk);

    send_byte("P"); recv_byte(r, ok); check(r == "B", $sformatf("ping reply %h", r));
    send_byte("Z"); recv_byte(r, ok); check(r == "?", $sformatf("unknown command reply %h", r));

    for (int i = 0; i < DEPTH; i++) cmd_write(i[7:0], {$random(seed), $random(seed)});
    for (int i = 0; i < DEPTH; i += 17) cmd_read_check(i[7:0]);
    cmd_read_check(8'(DEPTH - 1));

    cmd_write(0, 64'h8000_0000_0000_0001);
    cmd_write(1, 64'h0000_0000_0000_0040);
    cmd_exec(3'd0, 0, 0);                 // GET word0 bit0
    cmd_exec(3'd0, 0, 63);                // GET word0 bit63
    cmd_exec(3'd1, 0, 70);                // TEST word1 bit6
    cmd_exec(3'd2, 0, 5);  cmd_read_check(0);
    cmd_exec(3'd3, 0, 63); cmd_read_check(0);
    cmd_exec(3'd4, 8, 6);  cmd_read_check(1);   // base 8 = word 1
    cmd_exec(3'd4, 7, 9);  cmd_read_check(1);   // crosses into word 1
    cmd_exec(3'd2, DEPTH * 8 - 1, 7); cmd_read_check(8'(DEPTH - 1)); // last bit of RAM
    cmd_exec(3'd0, DEPTH * 8, 0);         // first byte past RAM: read fault
    cmd_exec(3'd2, 0, DEPTH * 64);        // first bit past RAM: fault, no write
    cmd_exec(3'd0, 64'hFFFF_FFFF_FFFF_FFFF, 0);
    cmd_exec(3'd5, 0, 0);                 // undefined opcode
    cmd_exec(3'd7, 0, 0);
    cmd_exec(3'd0, 0, 0);                 // clean op after errors
    for (int i = 0; i < 4; i++) cmd_read_check(i[7:0]);

    for (int n = 0; n < 300; n++) begin
      rop = $unsigned($random(seed)) % 8;
      if (rop > 4 && ($unsigned($random(seed)) % 3 != 0)) rop = rop - 3'd4;
      rb = $unsigned($random(seed)) % (DEPTH * 8);
      ro = $unsigned($random(seed)) % (DEPTH * 64);
      if ($unsigned($random(seed)) % 10 == 0) rb = {$random(seed), $random(seed)};
      cmd_exec(rop, rb, ro);
      if (n % 25 == 0) cmd_read_check(8'((rb >> 3) % DEPTH));
    end
    for (int i = 0; i < DEPTH; i++) cmd_read_check(i[7:0]);

    $display("checks=%0d fails=%0d", checks, fails);
    if (fails != 0) $fatal(1, "FAIL");
`ifdef TT_TOP
    $display("PASS: tt_um_snapkittyagent9nova_bitacc UART tests");
`else
    $display("PASS: fpga_top UART tests");
`endif
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "global timeout");
  end
endmodule
