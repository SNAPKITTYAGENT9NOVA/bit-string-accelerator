#!/usr/bin/env bash
# depth.sh LANES WORDS_PER_LANE WITH_MATCH: synthesize timing_top for XC7 and print
# the longest combinational path in mapped cells (LUTs, CARRY4, muxes), with
# flip-flops, block RAM and distributed RAM as path ends. A fast check before
# place and route: each LUT level costs roughly 0.1 ns of logic and 0.5-1.5 ns
# of routing on an XC7A100T.
set -euo pipefail
L=$1; W=$2; M=$3; tag=${L}x${W}_m${M}
mkdir -p build
yosys -p "read_verilog -sv ../rtl/bitacc_engine.sv ../rtl/bitacc_pcie_core.sv timing_top.sv; \
  chparam -set LANES $L -set WORDS_PER_LANE $W -set WITH_MATCH $M timing_top; \
  synth_xilinx -flatten -nowidelut -abc9 -arch xc7 -top timing_top; \
  ltp t:* t:FD* %d t:RAMB* %d t:RAM32M %d t:RAM64M %d t:IBUF %d t:OBUF %d t:BUFG %d" > build/depth_$tag.log 2>&1
awk '/Longest topological path/{f=1} f' build/depth_$tag.log | grep -vE "^$|End of script|Yosys|Time spent|CPU:" | head -40
