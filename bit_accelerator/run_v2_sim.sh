#!/bin/bash
# Build and run the cycle-accurate v2 testbench with Verilator (>= 5.0).
set -e
cd "$(dirname "$0")"
OUT=${OUT:-/tmp/vbuild_v2}
rm -rf "$OUT"
verilator --binary --timing -Wno-fatal -Wno-lint --top-module tb_bit_accelerator_v2 \
  -Mdir "$OUT" rtl/bit_accelerator_v2.sv testbenches/tb_bit_accelerator_v2.sv >/dev/null
"$OUT"/Vtb_bit_accelerator_v2
