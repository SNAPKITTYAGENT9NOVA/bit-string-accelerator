# Bit-String Hardware Accelerator

A dedicated hardware accelerator for bit-string operations with formal verification.

## Architecture Overview

```
request (base_address + bit_offset)
    ↓
STAGE 1: Address Generator (base + offset)
    ↓
STAGE 2: Word & Bit Index Calculator (÷64, mod 64)
    ↓
STAGE 3: Memory Access (TLB → L1 Cache)
    ↓
STAGE 4: Bit Extraction (barrel shifter + AND)
    ↓
STAGE 5: Writeback (register result)
    ↓
result (0 or 1)
```

## Supported Operations

- **BIT_GET** (0b000): Read single bit value
- **BIT_TEST** (0b001): Test bit and set condition flag
- **BIT_SET** (0b010): Set single bit to 1 (read-modify-write)
- **BIT_CLEAR** (0b011): Clear single bit to 0 (read-modify-write)
- **BIT_TOGGLE** (0b100): Toggle single bit (read-modify-write)

## Design versions

| Version | Files | Status |
|---------|-------|--------|
| **v2** | `rtl/bit_accelerator_v2.sv` | Verified design. Lint-clean (`verilator -Wall`), 182 testbench checks pass under Verilator and Icarus. |
| v1 | `rtl/bit_accelerator.sv` + submodules | Reference only, not built. `result_valid`/`result_bit` are driven from two processes, and its testbench does not compile. |

## Interface (v2)

```systemverilog
// Operation interface
input  logic        op_valid;       output logic op_ready;
input  logic [63:0] base_address;   // byte address
input  logic [63:0] bit_offset;     // bit offset from base
input  logic [2:0]  operation;      // 000 GET, 001 TEST, 010 SET, 011 CLEAR, 100 TOGGLE
output logic        result_valid;   // one-cycle pulse
output logic        result_bit;     // valid with result_valid
output logic        error;          // set by a read fault, valid with result_valid,
                                    // held until the next operation is accepted
// Memory interface (valid/ready)
output logic        mem_valid, mem_write;
output logic [63:0] mem_addr;       // 8-byte-aligned byte address
output logic [63:0] mem_wdata;      output logic [7:0] mem_wstrb;
input  logic        mem_ready, mem_rvalid, mem_fault;
input  logic [63:0] mem_rdata;
```

Opcodes 101-111 are undefined; v2 executes them as a read with no write.
Write faults are not modelled.

### Address calculation

```
absolute_bit = (base_address * 8) + bit_offset    (mod 2^64)
word_address = absolute_bit / 64
bit_index    = absolute_bit mod 64
result       = (memory[word_address] >> bit_index) & 1
```

## Directory structure

```
bit_accelerator/
├── rtl/bit_accelerator_v2.sv          # verified design
├── rtl/*.sv                           # v1 (reference only)
├── testbenches/tb_bit_accelerator_v2.sv
├── formal/bit_addressing.mlw          # specification + lemmas (Why3)
├── formal/bit_addressing_proofs.mlw   # derived lemmas
├── scripts/prove.sh                   # proves every goal; fails unless all are Valid
├── isa/BIT_ISA.md, docs/DATAPATH.md
├── Makefile, build.sh, run_v2_sim.sh
└── IMPLEMENTATION_REPORT.md           # measured results
```

## Build and verification

Prerequisites (Ubuntu 24.04): `apt-get install verilator iverilog why3 z3`, then `why3 config detect`.

```bash
make test           # lint + Verilator + Icarus simulation + Why3 proofs
make lint           # verilator --lint-only -Wall on v2
make sim            # v2 testbench under both simulators
make formal         # every Why3 goal must be proved by Z3
make formal-cvc4    # informational cross-check with CVC4
./build.sh          # same as make test, fails if a tool is missing
```

## Formal verification

`formal/` is checked by Why3 1.6 with Z3 4.8.12: **33/33 goals valid**, no
axioms beyond the Why3 standard library. The lemmas cover:

1. Address decomposition: `addr = word * 64 + bit`, `0 <= bit < 64`, and (word, bit) determines the address.
2. Boundaries: offset 64 reaches the next word; offsets 0-63 stay in one word **when the base is word-aligned** (`base mod 8 = 0`).
3. Bit operations: GET returns 0 or 1 and is deterministic; GET after SET/CLEAR returns 1/0.
4. Non-interference: SET or CLEAR on one word does not change a GET from another word.

An earlier draft of these files was not valid Why3 and stated three theorems
that are false (`bit_63_same_word`, `bit_index_wraps_at_64` without the
alignment condition, and `within_word_uniqueness`). Z3 proves their negations;
they were corrected.

The proofs are about the specification. Agreement between the specification
and the RTL is checked by simulation, not proved.

## Testing

`tb_bit_accelerator_v2.sv` is cycle-accurate and self-checking (exits non-zero
on any failure). It checks:

- GET results (set and clear bits, offset 64, non-zero base) and exact cycle timing
- SET/CLEAR/TOGGLE memory contents, including cross-word offsets
- one `result_valid` pulse per operation; `op_ready` low while busy
- read and write backpressure: request and data held stable, write committed once
- reset in each of READ_REQUEST, READ_WAIT, MODIFY, WRITE_REQUEST, WRITE_WAIT
- read faults on GET/SET/TOGGLE: `error` in the result cycle, no write, cleared by the next op
- undefined opcodes: no write

## Hardware estimates

The figures below are design targets, **not measured**: no synthesis,
place-and-route or power analysis has been run.

| Scenario | Latency |
|----------|---------|
| L1 cache hit | 4 cycles |
| L2 cache miss | 10-15 cycles |
| Memory miss | 50+ cycles |

- Gate count ~50k (7nm), area ~0.6 mm², power ~2.5 mW active, 1+ GHz

## Performance Comparison

### Traditional LOAD-SHIFT-AND Sequence

```
LOAD  r1, [base]         (3-50 cycles: cache/memory)
SHIFT r1, r1, offset     (1 cycle)
AND   r1, r1, 1          (1 cycle)
TOTAL: 5-52 cycles
```

### Dedicated BIT_GET Instruction

```
BIT_GET r1, base, offset (4-15 cycles: includes memory)
TOTAL: 4-15 cycles
IMPROVEMENT: 20-80% latency reduction
```

## Limitations & Future Work

### Current Scope
- 64-bit word size (fixed)
- Single-bit operations only (no multi-bit extract yet)
- No atomic multiword operations
- No GPU integration

### Future Extensions
- Variable-width field extraction
- Atomic compare-and-swap for multiword fields
- SIMD bit-parallel operations
- Hardware-assisted population count pipeline

## Design Philosophy

This accelerator prioritizes:

1. **Correctness**: Formal verification, not testing alone
2. **Determinism**: No undefined behavior, no race conditions
3. **Simplicity**: Minimal instruction set, orthogonal operations
4. **Performance**: Single-digit cycle latency on hits
5. **Verification**: Machine-checkable proofs, not documentation

## References

### Intel 64 & IA-32 Architecture
- Bit Manipulation Instructions (BMI, BMI2)
- BITFIELD, BIT_SET, BIT_CLEAR semantics

### Hardware Design
- Kogge-Stone parallel-prefix adder (address gen)
- Logarithmic barrel shifter (bit extraction)
- Standard pipelined memory interface

### Formal Methods
- Why3 platform for machine verification
- Euclidean division properties
- Non-interference proofs for memory operations

