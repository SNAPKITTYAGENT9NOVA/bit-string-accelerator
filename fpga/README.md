# FPGA build

Runs `rtl/bit_accelerator.sv` on real FPGA boards. The core's 64-bit buses do
not fit on package pins, so `rtl/fpga_top.sv` wraps it with:

- 256 × 64-bit words of block RAM (byte addresses 0-2047). Any other address
  answers with `mem_fault`, so the error path works on hardware.
- A UART command interface, 115200 baud 8N1.

| Board | FPGA | Clock | Top | Constraints |
|---|---|---|---|---|
| iCEBreaker | iCE40UP5K-SG48 | 12 MHz | `boards/icebreaker_top.sv` | `boards/icebreaker.pcf` |
| ULX3S | ECP5 LFE5U-25F CABGA381 | 25 MHz | `boards/ulx3s_top.sv` | `boards/ulx3s.lpf` |

LEDs: iCEBreaker red = last operation reported an error, green = heartbeat.
ULX3S `led[0]` = error, `led[1]` = busy, `led[7]` = heartbeat. The button resets.

## Build and program

Ubuntu 24.04: `sudo apt-get install yosys nextpnr-ice40 nextpnr-ecp5 fpga-icestorm fpga-trellis iverilog verilator`.

```sh
make icebreaker          # build/icebreaker.bin
make prog-icebreaker     # iceprog
make ulx3s               # build/ulx3s.bit (ULX3S_DEVICE=12k|25k|45k|85k to match your board)
make prog-ulx3s          # openFPGALoader --board ulx3s
```

Then, from the host (`cd host && cargo build --release`):

```sh
bitacc --port /dev/ttyUSB1 ping                 # pong
bitacc --port /dev/ttyUSB1 write 0 0x8000000000000001
bitacc --port /dev/ttyUSB1 exec get 0 63        # 1
bitacc --port /dev/ttyUSB1 exec toggle 0 5      # 1
bitacc --port /dev/ttyUSB1 read 0               # 0x8000000000000021
bitacc --port /dev/ttyUSB1 exec get 4096 0      # error (outside the RAM)
bitacc --port /dev/ttyUSB1 selftest 10000       # acceptance test, must report 0 mismatches
```

The iCEBreaker's UART is the FTDI's second interface (usually `/dev/ttyUSB1`).
On the ULX3S it is the only FTDI port (usually `/dev/ttyUSB0`).

`selftest` writes random data to all 256 words. It then runs random operations
(including out-of-range addresses and undefined opcodes) and checks every
status and the final RAM contents against a host model of the RTL.

## Protocol

All multi-byte fields are little-endian.

| Host → FPGA | FPGA → host | |
|---|---|---|
| `'P'` | `'B'` | ping |
| `'W'` idx[1] data[8] | `'K'` | write word |
| `'R'` idx[1] | data[8] | read word |
| `'X'` op[1] base[8] offset[8] | `0xA0 \| error<<1 \| bit` | run one operation |
| anything else | `'?'` | |

## Results

Yosys 0.33, nextpnr 0.6, place-and-route seeds 1-5:

| Board | Logic | Block RAM | Fmax (worst of 5 seeds) | Board clock |
|---|---|---|---|---|
| iCEBreaker | 1138 / 5280 LC (21%) | 4 / 30 | 39.06 MHz | 12 MHz |
| ULX3S 25F | 1171 / 24288 LUT4 (4%), 725 FF | 2 / 56 DP16KD | 73.22 MHz | 25 MHz |

## Verification

| Check | Command | Result |
|---|---|---|
| Lint, both board tops | `make lint` | `verilator -Wall` clean |
| UART-level testbench on RTL, Icarus + Verilator | `make sim` | 0 failures (7554 checks under Icarus, 7407 under Verilator; their random streams differ) |
| Same testbench on the iCE40 gate-level netlist (with the `SB_RAM40_4K` model) | `make gl-sim-ice40` | 7554 checks, 0 failures |
| Same testbench on the ECP5 gate-level netlist | `make gl-sim-ecp5` | 7554 checks, 0 failures |
| Host tool against the RTL through a pseudo-terminal | `make cosim` | `selftest` 2000 ops, 0 mismatches |

The testbench drives the serial line bit by bit. It checks pings, unknown
commands, all 256 words, directed operations (word crossing, last bit of RAM,
out-of-range reads, undefined opcodes) and 300 random operations against a
reference model. It also checks that TX idles high from power-up. Six of seven
hand-made faults in `fpga_top`/`uart_tx` are detected. The seventh (no
write-fault response) cannot occur: a write only follows a successful read of
the same word.

Two problems were found and fixed on the way:
- **TX powered up low.** FPGA flip-flops power up low, so TX started low and a
  host would read a junk byte.
- **Testbench race.** The testbench released reset on a clock edge, so the
  gate-level netlist saw a partial reset.

Limits:
- **Not run on a physical board.** Pin assignments are taken from each board's
  reference constraints and have not been checked against a board.
- **ECP5 block RAM is not covered at gate level.** Yosys 0.33 ships `DP16KD`
  only as a black box, so `gl-sim-ecp5` maps the memory to LUT RAM (`-nobram`).
  The `DP16KD` mapping is covered by place-and-route only. The iCE40
  gate-level run does include block RAM.
