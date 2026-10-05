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
| `fpga/` | Hardware build: UART + block-RAM wrapper, iCEBreaker and ULX3S bitstreams, host tool `bitacc` ([`fpga/README.md`](fpga/README.md)) |
| `asic/` | sky130 standard-cell synthesis, equivalence proof, timing ([`asic/README.md`](asic/README.md)) |
| `pcie/` | Parallel engine + PCIe core for the LiteFury, LiteX SoC, host program ([`pcie/README.md`](pcie/README.md)) |
| `tapeout/` | Tiny Tapeout (ttsky26d, sky130A) project, hardened and prechecked ([`tapeout/README.md`](tapeout/README.md), [`tapeout/SIGNOFF.md`](tapeout/SIGNOFF.md)) |
| `gpu/` | Rust/OpenCL (`ocl`) crate from `rust-opencl-gpu` |
| `.github/workflows/ci.yml` | CI: lint, simulation, proofs, SPICE, Rust |

## Requirements

Ubuntu 24.04:

```sh
sudo apt-get install iverilog verilator why3 z3 ngspice pocl-opencl-icd ocl-icd-opencl-dev \
  yosys nextpnr-ice40 nextpnr-ecp5 fpga-icestorm fpga-trellis
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
make fpga          # FPGA wrapper: lint, testbench, host co-simulation, both bitstreams
make fpga-gl       # FPGA wrapper on post-synthesis netlists (slow)
make asic          # sky130 synthesis + RTL/netlist equivalence proof
make pcie          # parallel engine + PCIe core vs the reference core
make tapeout       # Tiny Tapeout project: RTL test at both divisor settings
```

## Roadmap

Single-op core (reference, proofs) → parallel engine (`pcie/`, identical
results) → DMA work queue → LiteFury PCIe prototype → custom PCIe board, with
the Tiny Tapeout chip (`tapeout/`) as a separate silicon proof of the core.
The PCIe design does not depend on the transport, so the same card works in
the NUC's M.2 slot or in a USB4/Thunderbolt enclosure.

## Running on hardware

`make -C fpga icebreaker prog-icebreaker` (or `ulx3s prog-ulx3s`) builds and
loads a bitstream. Then `bitacc --port /dev/ttyUSB1 selftest` runs the on-board
acceptance test. See [`fpga/README.md`](fpga/README.md).

| Target | Size | Speed |
|---|---|---|
| iCE40UP5K (iCEBreaker), core + UART + RAM | 1138 LC (21%), 4 BRAM | 39.06 MHz (12 MHz board clock) |
| ECP5 25F (ULX3S), core + UART + RAM | 1171 LUT4 (4%), 2 BRAM | 73.22 MHz (25 MHz board clock) |
| sky130 HD standard cells, core only | 1538 cells, 10,063 µm² | 500 MHz pre-layout, typical corner |

GPU tests run serially (`RUST_TEST_THREADS=1`): PoCL 5.0 can abort with a
`pocl_release_dlhandle_cache` assertion when several OpenCL contexts are released
from different threads at the same time. With one test thread it passed 40 of
40 runs, against 26 of 40 with parallel threads.

## Known limits

- BIT_TEST behaves like BIT_GET; there is no separate condition flag output.
- `base_address << 3` drops the top 3 bits of `base_address` (64-bit wrap).
- The bitstreams have not been run on a physical board yet (no board was available); pin
  assignments come from the boards' reference constraint files.
- `asic/` numbers are pre-layout for the bare core. `tapeout/` has a full layout (GDS) of the
  Tiny Tapeout top that passes DRC, LVS, antenna, timing and the Tiny Tapeout precheck; it has
  not been submitted or fabricated. The SPICE deck is an RC model, not extracted silicon.
- The PCIe design has not run on a LiteFury: the bitstream needs Vivado, and its timing at
  125 MHz is unchecked. For single-bit operations it is not expected to beat the host CPU
  (see `pcie/README.md`).

The Windows OpenCL SDK and `OpenCL.lib` from `rust-opencl-gpu` are not included
here; the `ocl` crate locates the system OpenCL library.
