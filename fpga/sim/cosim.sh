#!/usr/bin/env bash
# End-to-end check of the host tool against the RTL: builds fpga_top with
# Verilator, bridges its UART to a pseudo-terminal (sim/uart_pty.cpp), and runs
# `bitacc selftest` through that terminal exactly as it would run on a board.
# Usage: sim/cosim.sh [operations] [seed]
set -euo pipefail
cd "$(dirname "$0")/.."
OPS=${1:-2000}
SEED=${2:-1}
BUILD=${BUILD:-build}
mkdir -p "$BUILD"
rm -rf "$BUILD/pty"
verilator --cc --exe --build -O2 --timescale 1ns/1ps -Wno-fatal -Wno-lint -GCLKS_PER_BIT=8 --top-module fpga_top \
  -Mdir "$BUILD/pty" -CFLAGS -DCPB=8 -LDFLAGS -lutil \
  ../rtl/bit_accelerator.sv rtl/uart_rx.sv rtl/uart_tx.sv rtl/word_memory.sv rtl/fpga_top.sv \
  "$PWD/sim/uart_pty.cpp" > "$BUILD/pty_build.log"
(cd host && cargo build --quiet --release)

rm -f "$BUILD/pty.path"
"$BUILD/pty/Vfpga_top" "$BUILD/pty.path" &
SIM=$!
trap 'kill $SIM 2>/dev/null || true; wait $SIM 2>/dev/null || true' EXIT
for _ in $(seq 100); do [ -s "$BUILD/pty.path" ] && break; sleep 0.1; done
PORT=$(cat "$BUILD/pty.path")
BITACC=host/target/release/bitacc

"$BITACC" --port "$PORT" ping
test "$("$BITACC" --port "$PORT" exec 6 0 0)" = error
"$BITACC" --port "$PORT" selftest "$OPS" "$SEED"
