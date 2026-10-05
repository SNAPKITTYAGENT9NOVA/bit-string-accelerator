## How it works

A small hardware accelerator for single-bit operations on 64-bit words. It
computes the bit's address and performs a read-modify-write when needed.

    effective bit = (base * 8) + offset          (64-bit arithmetic)
    word          = effective bit / 64
    bit index     = effective bit mod 64

| Opcode | Operation | Writes | Result bit |
|---|---|---|---|
| 0 | GET | no | the bit |
| 1 | TEST | no | the bit |
| 2 | SET | yes | 1 |
| 3 | CLEAR | yes | 0 |
| 4 | TOGGLE | yes | the new bit |
| 5-7 | undefined | no | error |

The chip holds 4 words of RAM (byte addresses 0-31). An address outside that
range ends the operation with an error and never writes.

Everything is driven over a UART (8 data bits, no parity, 1 stop bit). All
multi-byte fields are little-endian:

| Host sends | Chip replies | |
|---|---|---|
| `P` | `B` | ping |
| `W` idx data[8] | `K` | write word idx (0-3) |
| `R` idx | data[8] | read word idx |
| `X` op base[8] offset[8] | `0xA0` + 2·error + bit | run one operation |
| anything else | `?` | |

The design is the `bit_accelerator` core from
https://github.com/SNAPKITTYAGENT9NOVA/bit-string-accelerator. Before
hardening it was checked as follows:
- a self-checking testbench, with random backpressure, read latency and fault injection
- Why3 proofs of the address arithmetic
- the same RTL running on iCE40 and ECP5 FPGAs
- a formal equivalence proof of its sky130 netlist

## How to test

1. Set the clock, and set the UART divisor pins to match it. The chip uses
   `4 × d` clocks per bit, where `d = {ui[7:4], ui[2:0]}`. With all divisor
   pins low it uses 104 clocks per bit, which is 115200 baud at a 12 MHz clock.
   Other examples:

   | Clock | Baud | d | ui[7:4] | ui[2:0] |
   |---|---|---|---|---|
   | 12 MHz | 115200 | 0 (default) | 0000 | 000 |
   | 25 MHz | 115200 | 54 (216 clocks) | 0110 | 110 |
   | 50 MHz | 115200 | 108 (432 clocks) | 1101 | 100 |

2. Connect a 3.3 V USB-UART adapter: adapter TX to `ui[3]` (RX), adapter RX to
   `uo[4]` (TX).
3. Reset the design. `uo[0]` is high while an operation runs. `uo[1]` is the
   last operation's error flag. `uo[2]` is its result bit.
4. Use the host tool from the repository (`fpga/host`, Rust):

       bitacc --port /dev/ttyUSB0 --words 4 ping                  # pong
       bitacc --port /dev/ttyUSB0 --words 4 write 0 0x8000000000000001
       bitacc --port /dev/ttyUSB0 --words 4 exec get 0 63         # 1
       bitacc --port /dev/ttyUSB0 --words 4 exec toggle 0 5       # 1
       bitacc --port /dev/ttyUSB0 --words 4 read 0                # 0x8000000000000021
       bitacc --port /dev/ttyUSB0 --words 4 exec get 32 0         # error (outside RAM)
       bitacc --port /dev/ttyUSB0 --words 4 selftest 10000        # 0 mismatches

`selftest` runs random operations, including faults and undefined opcodes,
and checks every reply and the final RAM contents against a model of the
design.

## External hardware

A 3.3 V USB-UART adapter (for example an FTDI or CP2102 cable) on `ui[3]`/`uo[4]`.
