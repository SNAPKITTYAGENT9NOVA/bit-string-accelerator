# Parallel bit-operation engine (rtl/bitacc_engine.sv) for the PCIe accelerator.
#
#   make lint     verilator -Wall
#   make sim      equivalence against the single-op reference core: several
#                 lane/memory geometries and seeds, Icarus Verilog
#   make sim-verilator   the default geometry under Verilator
#
# The testbench fails unless results and final memory equal the reference, and
# unless out-of-order completion, a full reorder buffer and every operation
# class (in range, out of range, wrapping addresses, undefined opcodes) occurred.

IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator
BUILD     ?= build
OPS       ?= 4000

REF    := ../rtl/bit_accelerator.sv
ENGINE := rtl/bitacc_engine.sv
TB     := tb/tb_engine.sv
# lanes x words-per-lane
GEOMETRIES := 2x4 4x16 8x16 8x512
SEEDS      := 1 7

.PHONY: all lint sim sim-verilator clean
.DEFAULT_GOAL := all
all: lint sim sim-verilator

lint:
	$(VERILATOR) --lint-only -Wall $(ENGINE)

sim:
	@mkdir -p $(BUILD)
	@set -e; for g in $(GEOMETRIES); do \
	  l=$${g%x*}; w=$${g#*x}; rm -f $(BUILD)/tb_$$g.vvp; \
	  $(IVERILOG) -g2012 -DLANES=$$l -DWPL=$$w -o $(BUILD)/tb_$$g.vvp $(REF) $(ENGINE) $(TB); \
	  for s in $(SEEDS); do $(VVP) -n $(BUILD)/tb_$$g.vvp +seed=$$s +ops=$(OPS) | grep -E '^(checks|PASS)'; done; \
	done

sim-verilator:
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
	  --top-module tb_engine -Mdir $(BUILD)/verilator $(REF) $(ENGINE) $(TB) >/dev/null
	$(BUILD)/verilator/Vtb_engine +ops=$(OPS)

clean:
	rm -rf $(BUILD)
