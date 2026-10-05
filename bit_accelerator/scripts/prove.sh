#!/usr/bin/env bash
# Prove every goal of the given Why3 files with one prover.
# Usage: scripts/prove.sh [-P prover] [-t seconds] [-L dir] file.mlw...
# Goals are split with the split_vc transformation before proving.
# Prints one line per goal and exits non-zero unless every goal is Valid.
set -euo pipefail
prover=z3; timelimit=30; loadpath=()
while getopts "P:t:L:" opt; do
  case "$opt" in
    P) prover=$OPTARG ;;
    t) timelimit=$OPTARG ;;
    L) loadpath+=(-L "$OPTARG") ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || { echo "usage: $0 [-P prover] [-t s] [-L dir] file.mlw..." >&2; exit 2; }
command -v why3 >/dev/null || { echo "why3 not found" >&2; exit 2; }

total=0; bad=0
for f in "$@"; do
  out=$(why3 prove "${loadpath[@]}" -a split_vc -P "$prover" -t "$timelimit" "$f" 2>&1) || true
  results=$(printf '%s\n' "$out" | awk '
    /^Goal / { goal = $2; sub(/\.$/, "", goal) }
    /Prover result is:/ { r = $0; sub(/.*Prover result is: /, "", r); print goal "\t" r }')
  if [ -z "$results" ]; then
    echo "ERROR $f: no goals reported"; printf '%s\n' "$out" | head -20; bad=$((bad + 1)); continue
  fi
  while IFS=$'\t' read -r goal res; do
    total=$((total + 1))
    case "$res" in
      Valid*) printf '  ok    %-40s %s\n' "$(basename "$f"):$goal" "$res" ;;
      *) printf '  FAIL  %-40s %s\n' "$(basename "$f"):$goal" "$res"; bad=$((bad + 1)) ;;
    esac
  done <<< "$results"
done
echo "why3/$prover: $((total - bad))/$total goals valid"
[ "$bad" -eq 0 ]
