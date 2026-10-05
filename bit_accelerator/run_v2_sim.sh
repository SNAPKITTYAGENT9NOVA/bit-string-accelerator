#!/usr/bin/env bash
# Build and run the cycle-accurate v2 testbench with Verilator (>= 5.0).
# Exits non-zero if any check fails ($fatal in the testbench).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${OUT:-build/verilator}
rm -rf "$OUT" && mkdir -p "$OUT"
verilator --binary --timing -Wall -Wno-fatal --top-module tb_bit_accelerator_v2 \
  -Mdir "$OUT" rtl/bit_accelerator_v2.sv testbenches/tb_bit_accelerator_v2.sv >/dev/null
"$OUT"/Vtb_bit_accelerator_v2
