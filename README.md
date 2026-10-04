# bit-string-accelerator

[![CI](https://github.com/SNAPKITTYAGENT9NOVA/bit-string-accelerator/actions/workflows/ci.yml/badge.svg)](https://github.com/SNAPKITTYAGENT9NOVA/bit-string-accelerator/actions/workflows/ci.yml)

Synthesizable SystemVerilog bit-string accelerator for deterministic 64-bit-word bit addressing.

    effective_bit_address = (base_address * 8) + bit_offset     (mod 2^64)
    word_address          = (effective_bit_address / 64) * 8
    bit_index             = effective_bit_address mod 64

Operations: GET, TEST, SET, CLEAR, TOGGLE. Interface contract and verification
evidence: [`docs/verification.md`](docs/verification.md).

## Layout

| Path | Contents |
|------|----------|
| `rtl/`, `verification/`, `formal/`, `isa/`, `spice/`, `docs/` | Compact accelerator, its self-checking testbench, Why3 proofs, ISA and timing model |
| `bit_accelerator/` | Multi-stage v2 accelerator with its own testbench and proofs (also in `rust-opencl-gpu`) |
| `gpu/` | Rust/OpenCL (`ocl`) crate from `rust-opencl-gpu` |
| `.github/workflows/ci.yml` | CI: lint, simulation, proofs, SPICE, Rust |

## Requirements

Ubuntu 24.04:

```sh
sudo apt-get install iverilog verilator why3 z3 ngspice pocl-opencl-icd ocl-icd-opencl-dev
why3 config detect
```

plus a Rust toolchain (1.85 or newer) for `gpu/`. `pocl-opencl-icd` provides a
CPU OpenCL device; any other OpenCL driver works too.

## Build and test

```sh
make test          # everything CI runs
make lint          # verilator -Wall
make sim           # testbench under Icarus and Verilator (SEED=n OPS=n to vary)
make formal        # Why3 proofs, every goal must be proved by Z3
make spice         # ngspice timing model
make accel         # bit_accelerator/ v2: lint, sim, proofs
make gpu           # gpu/: cargo fmt, clippy, tests
```

GPU tests run serially (`RUST_TEST_THREADS=1`): PoCL 5.0 can abort with a
`pocl_release_dlhandle_cache` assertion when several OpenCL contexts are released
from different threads at the same time. With one test thread it passed 40 of
40 runs, against 26 of 40 with parallel threads.

## Known limits

- BIT_TEST behaves like BIT_GET; there is no separate condition flag output.
- `base_address << 3` drops the top 3 bits of `base_address` (64-bit wrap).
- No synthesis has been run; the SPICE deck is an RC timing model, not extracted silicon.

The Windows OpenCL SDK and `OpenCL.lib` from `rust-opencl-gpu` are not included
here; the `ocl` crate locates the system OpenCL library.
