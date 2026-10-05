# bit_accelerator_v2 - Verified Status

Everything below was measured by running `make test` (Verilator 5.020, Icarus Verilog 12.0,
Why3 1.6.0 with Z3 4.8.12).

## Result
- Simulation: `checks=182 fails=0` under both Verilator and Icarus.
- Lint: `verilator --lint-only -Wall` clean.
- Formal: 33/33 Why3 goals valid with Z3.

## Observed cycle timing (1-cycle-latency memory, no stalls)
a = cycle in which `op_valid && op_ready` is sampled.

| Op | Timeline |
|----|----------|
| BIT_GET | READ_REQUEST a+1, READ_RESPONSE a+2, RESULT_VALID a+3 (one cycle) |
| SET/CLEAR/TOGGLE | READ_REQUEST a+1, READ_RESPONSE a+2, MODIFY a+3, WRITE accepted a+4, RESULT_VALID a+6 |
| Write stalled (`mem_ready=0` a+4..a+6) | request and wdata held, accepted a+7, RESULT_VALID a+9 |
| Read stalled (`mem_ready=0` a+1..a+2) | accepted a+3, response a+4, RESULT_VALID a+5 |

## Covered by the testbench
- Result value for GET (set/clear bits, cross-word offsets, non-zero base).
- Memory contents after SET/CLEAR/TOGGLE, including word 1 targets.
- Exactly one `result_valid` pulse per op; `op_ready` low while busy.
- Write and read backpressure: signals held stable, no early result, write committed once.
- Reset asserted in each of READ_REQUEST, READ_WAIT, MODIFY, WRITE_REQUEST, WRITE_WAIT:
  no `result_valid`, no write after reset, DUT idle, and a fresh op completes normally.

## Defects found by simulation and fixed
1. `result_valid` was registered, so it appeared one cycle later than specified (a+4 instead of a+3).
   It is now combinational from `ST_RESULT`.
2. A reset in the same cycle as a write handshake let the memory commit the write.
   `mem_valid/mem_write/mem_wstrb/mem_wdata` are now forced low while `reset` is asserted.
3. `error` was set on any `mem_fault`; it is now cleared on accept and set only in `ST_READ_WAIT`.
4. Read-fault tests were added (GET/SET/TOGGLE): `error` is high in the result cycle, no write
   is issued, and the next operation clears it. The testbench now exits non-zero on failure.
5. Lint fixes: explicit zero-extension of `mem_addr`, bit extraction reads `read_word[bit_index]` directly.
6. The previous testbench did not compile, sampled after the clock edge (racy), and modeled
   2-cycle read latency. It was rewritten to log pre-edge values per cycle.

## Not verified / known limits
- Only read faults exist; there is no write-fault input path.
- `BIT_TEST` (3'b001) behaves like GET; no flag output exists.
- `base_address << 3` truncates the top 3 bits of `base_address`, and `mem_addr` is 61 significant bits.
- The Why3 proofs cover the specification; RTL-to-specification agreement is checked by simulation only.
- Undefined opcodes (101-111) execute as a read with no write and no error.
- No synthesis was run; area/power/frequency numbers elsewhere in this repo are estimates.
