#!/usr/bin/env bash
# Runs every check (lint, Verilator + Icarus simulation, Why3 proofs) and exits
# non-zero if any fails. Missing tools are reported as failures, not passes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
for tool in verilator iverilog vvp why3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
make test
