# bit-string-accelerator

Synthesizable SystemVerilog bit-string accelerator for deterministic 64-bit-word bit addressing.

    effective_bit_address = (base_address * 8) + bit_offset
    word_address          = (effective_bit_address / 64) * 8
    bit_index             = effective_bit_address mod 64

Operations: GET, TEST, SET, CLEAR, TOGGLE.

## Layout

| Path | Contents |
|------|----------|
| `rtl/`, `verification/`, `formal/`, `isa/`, `spice/`, `docs/`, `Makefile` | Compact accelerator (iverilog + Why3) |
| `bit_accelerator/` | Previously tested multi-stage accelerator (v1 + v2 RTL, testbenches, Why3 proofs, ISA, reports), ported unchanged from `rust-opencl-gpu` |
| `gpu/` | Ported Rust/OpenCL (`ocl`) GPU crate from `rust-opencl-gpu` (`cargo test` needs an OpenCL device) |

The Windows OpenCL SDK and `OpenCL.lib` from the source repo were intentionally not ported (binary, platform-specific; the `ocl` crate locates OpenCL itself).
