#!/bin/bash
# Runs the checks that actually exist and reports their real outcome.
# Exit status is non-zero if any check fails. Nothing here is hardcoded as "passed".
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL=0
step() { printf '\n=== %s ===\n' "$1"; }

step "v2 cycle-accurate simulation (Verilator)"
if command -v verilator >/dev/null 2>&1; then
    ./run_v2_sim.sh || FAIL=1
else
    echo "SKIPPED: verilator not found (this is NOT a pass)"; FAIL=1
fi

step "Formal files (Why3)"
# Why3 reads .mlw files; the .why3 sources are checked via a temporary .mlw copy.
if command -v why3 >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    for f in formal/*.why3; do
        cp "$f" "$TMP/$(basename "${f%.why3}").mlw"
    done
    for f in "$TMP"/*.mlw; do
        echo "-- $(basename "$f")"
        why3 prove -P z3 --timelimit 10 "$f" || { echo "FAILED: $(basename "$f")"; FAIL=1; }
    done
    rm -rf "$TMP"
else
    echo "SKIPPED: why3 not found (this is NOT a pass)"; FAIL=1
fi

step "Summary"
if [ "$FAIL" -eq 0 ]; then echo "all checks passed"; else echo "one or more checks FAILED or were skipped"; fi
exit "$FAIL"
