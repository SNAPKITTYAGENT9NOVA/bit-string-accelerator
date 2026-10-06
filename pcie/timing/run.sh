#!/usr/bin/env bash
# run.sh LANES WORDS_PER_LANE WITH_MATCH: synthesize timing_top and place & route it
# for the XC7A100T-FGG484-2 at 125 MHz with nextpnr-xilinx; prints utilisation and Fmax.
set -euo pipefail
L=$1; W=$2; M=$3; tag=${L}x${W}_m${M}
NEXTPNR=${NEXTPNR:-nextpnr-xilinx}; CHIPDB=${CHIPDB:?set CHIPDB to the xc7a100t chip database}
mkdir -p build
yosys -q -l build/synth_$tag.log -p "read_verilog -sv ../rtl/bitacc_engine.sv ../rtl/bitacc_pcie_core.sv timing_top.sv; \
  chparam -set LANES $L -set WORDS_PER_LANE $W -set WITH_MATCH $M timing_top; \
  synth_xilinx -flatten -nowidelut -abc9 -arch xc7 -top timing_top; tee -q -o build/stat_$tag.txt stat; \
  write_json build/$tag.json" > /dev/null 2>&1
$NEXTPNR --chipdb "$CHIPDB" --xdc timing_top.xdc --json build/$tag.json --freq 125 \
  --report build/report_$tag.json > build/pnr_$tag.log 2>&1 || { tail -20 build/pnr_$tag.log; exit 1; }
grep -E "SLICE_LUTX:|SLICE_FFX:|RAMB36E1:" build/pnr_$tag.log | tail -3
grep "Max frequency" build/pnr_$tag.log | tail -1
