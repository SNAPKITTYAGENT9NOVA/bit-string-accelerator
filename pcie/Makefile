# PCIe accelerator: parallel engine, PCIe-facing core, LiteX SoC for the
# LiteFury, and the host program.
#
#   make lint           verilator -Wall on the engine and the PCIe core
#   make sim            engine vs the single-op reference core: several
#                       geometries and seeds (Icarus); core with 128-bit streams.
#                       The runs are independent targets: use make -j.
#   make sim-verilator  the engine testbench under Verilator
#   make soc            generate the LiteX SoC sources and Linux driver (no Vivado)
#   make cosim          host program (host/bitacc_pcie.c) against the Verilated core
#                       through a liblitepcie stand-in (needs `make soc` first)
#   make perf           engine throughput in clock cycles at the LiteFury geometry
#                       (8 lanes x 2048 words): host bench against the Verilated core
#   make bitstream      full build with Vivado (not available in CI)
#
# The engine testbench fails unless results and final memory equal the
# reference, and unless out-of-order completion, a full reorder buffer, both
# directions of the range barrier and every operation class (single-bit and
# range; in range, out of range, wrapping, undefined) occurred.
#
# A testbench passes only if vvp exits 0 and prints PASS. (Piping vvp into
# grep would report the grep's status, so a failing run would pass.)

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
TB_INC     := tb/gold_ops.svh tb/range_stim.svh
ENGINE_RUNS := $(foreach g,$(GEOMETRIES),$(foreach s,$(SEEDS),run-$(g)-$(s)))

# $(call vvp_check,command,log): run, show the summary, fail unless exit 0 and PASS.
define vvp_check
$(1) > $(2) 2>&1; rc=$$?; grep -E '^(stimulus|range coverage|checks|PASS|FAIL)' $(2); \
  test $$rc -eq 0 && grep -q '^PASS' $(2)
endef

.PHONY: all lint sim sim-engine sim-core sim-verilator soc cosim perf bitstream clean $(ENGINE_RUNS)
.DEFAULT_GOAL := all
all: lint sim sim-verilator

lint:
	$(VERILATOR) --lint-only -Wall $(ENGINE)
	$(VERILATOR) --lint-only -Wall $(ENGINE) $(CORE) --top-module bitacc_pcie_core

sim: sim-engine sim-core

sim-engine: $(ENGINE_RUNS)

# run-<lanes>x<words per lane>-<seed>
.SECONDEXPANSION:
$(ENGINE_RUNS): run-%: $(BUILD)/tb_$$(word 1,$$(subst -, ,$$*)).vvp
	@echo "engine $*"
	@$(call vvp_check,$(VVP) -n $< +seed=$(word 2,$(subst -, ,$*)) +ops=$(OPS),$(BUILD)/run-$*.log)

$(BUILD)/tb_%.vvp: $(REF) $(ENGINE) tb/tb_engine.sv $(TB_INC)
	@mkdir -p $(BUILD)
	g=$*; $(IVERILOG) -g2012 -Itb -DLANES=$${g%x*} -DWPL=$${g#*x} -o $@ $(REF) $(ENGINE) tb/tb_engine.sv

sim-core:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -Itb -o $(BUILD)/tb_core.vvp $(REF) $(ENGINE) $(CORE) tb/tb_pcie_core.sv
	@$(call vvp_check,$(VVP) -n $(BUILD)/tb_core.vvp,$(BUILD)/core.log)

sim-verilator:
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style -Itb \
	  --top-module tb_engine -Mdir $(BUILD)/verilator $(REF) $(ENGINE) tb/tb_engine.sv >/dev/null
	@$(call vvp_check,$(BUILD)/verilator/Vtb_engine +ops=$(OPS),$(BUILD)/verilator.log)

soc:
	cd litex && $(PYTHON) bitacc_litefury.py --driver --output-dir $(SOC_DIR)

# $(call cosim_build,dir,lanes,words per lane): host program + Verilated core + mock.
define cosim_build
	@test -d $(DRIVER) || { echo "run 'make soc' first"; exit 1; }
	@mkdir -p $(1)
	cc -O2 -Wall -Wextra -Werror -I$(DRIVER)/user/liblitepcie -I$(DRIVER)/kernel \
	  -c -o $(abspath $(1))/bitacc_pcie.o host/bitacc_pcie.c
	$(VERILATOR) --cc --exe --build -O2 --timescale 1ns/1ps -Wno-fatal -Wno-lint \
	  -GLANES=$(2) -GWORDS_PER_LANE=$(3) --top-module bitacc_pcie_core -Mdir $(1)/obj \
	  -CFLAGS "-I$(DRIVER)/user/liblitepcie -I$(DRIVER)/kernel -DMOCK_LANES=$(2) -DMOCK_WPL=$(3)" \
	  -LDFLAGS "$(abspath $(1))/bitacc_pcie.o" \
	  $(ENGINE) $(CORE) $(abspath host/sim/mock_litepcie.cpp) -o bitacc_pcie_cosim >/dev/null
endef

# Small geometry keeps the co-simulation fast; the host reads it from CSRs.
# Arguments: operations, seed, percentage of range operations.
cosim:
	$(call cosim_build,$(BUILD)/cosim,4,64)
	$(BUILD)/cosim/obj/bitacc_pcie_cosim selftest 200000 1 5
	$(BUILD)/cosim/obj/bitacc_pcie_cosim selftest 50000 9 50

# Fails if a bench needs more cycles per descriptor than the design intends:
# single-bit 1 (plus 2%), COUNT/FIND over 16384 words 16384/8 steps of 1 cycle,
# BULK over 8192 words 8192/8 steps of 2 cycles (plus 1% and a fixed 16 for
# pipeline fill).
perf:
	$(call cosim_build,$(BUILD)/perf,8,2048)
	$(BUILD)/perf/obj/bitacc_pcie_cosim selftest 20000 3 20
	@for kl in get:1.02 count:2084 find:2084 xor:2084; do \
	  k=$${kl%:*}; limit=$${kl#*:}; n=$$( [ $$k = get ] && echo 200000 || echo 2048 ); \
	  out=$$($(BUILD)/perf/obj/bitacc_pcie_cosim bench $$k $$n 2>&1) || { echo "$$out"; exit 1; }; \
	  echo "$$out" | grep -E '^(bench|mock)'; \
	  echo "$$out" | awk -v l=$$limit '/^mock:/ { c = $$(NF-1) } END { if (c == "" || c + 0 > l) { print "cycles/descriptor " c " above " l; exit 1 } }' || exit 1; \
	done

bitstream:
	cd litex && $(PYTHON) bitacc_litefury.py --build --driver --output-dir $(SOC_DIR)

clean:
	rm -rf $(BUILD) host/build_cosim
