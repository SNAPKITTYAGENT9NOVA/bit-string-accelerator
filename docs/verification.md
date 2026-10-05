# Verification Contract

Applies to `rtl/bit_accelerator.sv`.

## Interface

- Reset is synchronous and active-high. Reset cancels any uncompleted operation
  and suppresses its result. `op_ready` is low while `reset` is high.
- An operation is accepted on a cycle with `op_valid && op_ready`. `op_ready`
  stays low until the operation's result pulse.
- A read request completes on `mem_valid && !mem_write && mem_ready`; its data
  completes on `mem_rvalid`. A read fault is signalled with `mem_fault` instead
  of `mem_rvalid`.
- A write request completes on `mem_valid && mem_write && mem_ready`. The cycle
  after the write handshake, `mem_fault` reports a write fault.
- `mem_addr` is `((base_address << 3) + bit_offset) >> 6 << 3` (64-bit
  arithmetic); `mem_wstrb` is all ones.
- `result_valid` is a one-cycle pulse. `error` and `result_bit` are valid in the
  same cycle. On `error`, `result_bit` keeps its previous value.

## Operations

| Opcode | Op | Writes | `result_bit` |
|---|---|---|---|
| 000 | GET | no | bit value |
| 001 | TEST | no | bit value |
| 010 | SET | yes | 1 |
| 011 | CLEAR | yes | 0 |
| 100 | TOGGLE | yes | new bit value |
| 101-111 | undefined | no | `error = 1` |

A read fault ends the operation with `error = 1` and no write. A write fault
reports `error = 1`; whether the memory kept the write is up to the memory.

## Evidence

| Check | Tool | Result |
|---|---|---|
| Lint | `verilator --lint-only -Wall` | clean |
| Simulation | `verification/tb_bit_accelerator.sv`, Icarus 12 and Verilator 5.020 | 0 failures; 23 directed operations, 12 reset-cancellation cases, 2000 random operations per seed with backpressure, read latency 0-3 and fault injection |
| Mutation | 7 hand-made RTL mutants (wrong bit index, wrong address, SET as XOR, ...) | all detected |
| Proofs | `formal/*.mlw`, Why3 1.6 + Z3 4.8.12 | 38/38 goals valid |
| Timing model | `spice/bit_extract.sp`, ngspice 42 | tpd ≈ 94 ps (RC model, not extracted silicon) |
| FPGA wrapper | `fpga/tb/tb_fpga_top.sv` over the UART: RTL (Icarus, Verilator), iCE40 and ECP5 gate-level netlists | 0 failures on each |
| Host tool | `fpga/sim/cosim.sh`: `bitacc selftest` against the RTL through a pseudo-terminal | 2000 operations, 0 mismatches |
| FPGA place-and-route | nextpnr, 5 seeds | iCE40UP5K 39.06 MHz, ECP5-25F 73.22 MHz; both meet board clocks |
| ASIC synthesis | Yosys + ABC on sky130_fd_sc_hd, OpenSTA | 1538 cells, 10,063 µm², netlist proved equal to RTL, 500 MHz pre-layout |

`formal/bit_address.mlw` proves that the RTL's shift/mask datapath equals the
integer address specification when `(base << 3) + offset` does not overflow.
Its trusted base is four facts from the Why3 bit-vector library (listed in the
file), restated because the SMT drivers do not pass them to the solver.
`formal/bit_extract.mlw` proves GET/SET/CLEAR/TOGGLE on 64-bit words change
exactly the target bit.

The proofs are about the datapath expressions; the state machine is checked by
simulation. Random seeds reproduce within one simulator only (Icarus and
Verilator implement `$random` differently).
