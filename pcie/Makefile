# PCIe accelerator: parallel engine, PCIe-facing core, LiteX SoC for the
# LiteFury, and the host program.
#
#   make lint           verilator -Wall on the engine and the PCIe core
#   make sim            engine vs the single-op reference core: several
#                       geometries and seeds (Icarus); core with 128-bit streams
#   make sim-verilator  the engine testbench under Verilator
#   make soc            generate the LiteX SoC sources and Linux driver (no Vivado)
#   make cosim          host program (host/bitacc_pcie.c) against the Verilated core
#                       through a liblitepcie stand-in (needs `make soc` first)
#   make bitstream      full build with Vivado (not available in CI)
#
# The engine testbench fails unless results and final memory equal the
# reference, and unless out-of-order completion, a full reorder buffer and
# every operation class (in range, out of range, wrapping, undefined) occurred.

IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator
PYTHON    ?= python3
BUILD     ?= build
OPS       ?= 4000

REF    := ../rtl/bit_accelerator.sv
ENGINE := rtl/bitacc_engine.sv
CORE   := rtl/bitacc_pcie_core.sv
SOC_DIR := $(abspath $(BUILD))/litefury
DRIVER  := $(SOC_DIR)/driver
GEOMETRIES := 2x4 4x16 8x16 8x512
SEEDS      := 1 7

.PHONY: all lint sim sim-engine sim-core sim-verilator soc cosim bitstream clean
.DEFAULT_GOAL := all
all: lint sim sim-verilator

lint:
	$(VERILATOR) --lint-only -Wall $(ENGINE)
	$(VERILATOR) --lint-only -Wall $(ENGINE) $(CORE) --top-module bitacc_pcie_core

sim: sim-engine sim-core

sim-engine:
	@mkdir -p $(BUILD)
	@set -e; for g in $(GEOMETRIES); do \
	  l=$${g%x*}; w=$${g#*x}; rm -f $(BUILD)/tb_$$g.vvp; \
	  $(IVERILOG) -g2012 -DLANES=$$l -DWPL=$$w -o $(BUILD)/tb_$$g.vvp $(REF) $(ENGINE) tb/tb_engine.sv; \
	  for s in $(SEEDS); do $(VVP) -n $(BUILD)/tb_$$g.vvp +seed=$$s +ops=$(OPS) | grep -E '^(checks|PASS)'; done; \
	done

sim-core:
	@mkdir -p $(BUILD)
	@rm -f $(BUILD)/tb_core.vvp
	$(IVERILOG) -g2012 -o $(BUILD)/tb_core.vvp $(REF) $(ENGINE) $(CORE) tb/tb_pcie_core.sv
	$(VVP) -n $(BUILD)/tb_core.vvp | grep -E '^(stimulus|checks|PASS)'

sim-verilator:
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
	  --top-module tb_engine -Mdir $(BUILD)/verilator $(REF) $(ENGINE) tb/tb_engine.sv >/dev/null
	$(BUILD)/verilator/Vtb_engine +ops=$(OPS)

soc:
	cd litex && $(PYTHON) bitacc_litefury.py --driver --output-dir $(SOC_DIR)

# Small geometry keeps the co-simulation fast; the host reads it from CSRs.
cosim:
	@test -d $(DRIVER) || { echo "run 'make soc' first"; exit 1; }
	@mkdir -p $(BUILD)/cosim
	cc -O2 -Wall -Wextra -Werror -I$(DRIVER)/user/liblitepcie -I$(DRIVER)/kernel \
	  -c -o $(abspath $(BUILD))/cosim/bitacc_pcie.o host/bitacc_pcie.c
	$(VERILATOR) --cc --exe --build -O2 --timescale 1ns/1ps -Wno-fatal -Wno-lint \
	  -GLANES=4 -GWORDS_PER_LANE=64 --top-module bitacc_pcie_core -Mdir $(BUILD)/cosim/obj \
	  -CFLAGS "-I$(DRIVER)/user/liblitepcie -I$(DRIVER)/kernel -DMOCK_LANES=4 -DMOCK_WPL=64" \
	  -LDFLAGS "$(abspath $(BUILD))/cosim/bitacc_pcie.o" \
	  $(ENGINE) $(CORE) $(abspath host/sim/mock_litepcie.cpp) -o bitacc_pcie_cosim >/dev/null
	$(BUILD)/cosim/obj/bitacc_pcie_cosim selftest 200000 1
	$(BUILD)/cosim/obj/bitacc_pcie_cosim selftest 50000 9

bitstream:
	cd litex && $(PYTHON) bitacc_litefury.py --build --driver --output-dir $(SOC_DIR)

clean:
	rm -rf $(BUILD) host/build_cosim
