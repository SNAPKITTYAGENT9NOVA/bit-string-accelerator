# bit_accelerator build and verification.
#
# The verified design is bit_accelerator_v2 (rtl/bit_accelerator_v2.sv).
# The v1 sources (bit_accelerator.sv and its submodules) are kept for reference
# only and are not built: v1 multiply-drives result_valid/result_bit and its
# testbench does not compile. See README.md, "Design versions".

VERILATOR   ?= verilator
IVERILOG    ?= iverilog
VVP         ?= vvp
WHY3_PROVER ?= z3
WHY3_TIME   ?= 30
BUILD       ?= build

V2_RTL  := rtl/bit_accelerator_v2.sv
V2_TB   := testbenches/tb_bit_accelerator_v2.sv
FORMAL  := formal/bit_addressing.mlw formal/bit_addressing_proofs.mlw

.PHONY: help all test lint sim sim-verilator sim-icarus formal formal-cvc4 clean
.DEFAULT_GOAL := help

all test: lint sim formal

lint:
	$(VERILATOR) --lint-only -Wall $(V2_RTL)

sim: sim-verilator sim-icarus

sim-verilator:
	OUT=$(abspath $(BUILD))/verilator ./run_v2_sim.sh

sim-icarus:
	mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb_v2.vvp $(V2_RTL) $(V2_TB)
	$(VVP) -n $(BUILD)/tb_v2.vvp

formal:
	./scripts/prove.sh -P $(WHY3_PROVER) -t $(WHY3_TIME) -L formal $(FORMAL)

# Cross-check with CVC4. Informational: CVC4 does not discharge every goal
# within the time limit, Z3 does.
formal-cvc4:
	-./scripts/prove.sh -P cvc4 -t $(WHY3_TIME) -L formal $(FORMAL)

clean:
	rm -rf $(BUILD) obj_dir

help:
	@echo "make test           lint + both simulators + Why3 proofs"
	@echo "make lint           verilator -Wall on the v2 RTL"
	@echo "make sim            v2 testbench under Verilator and Icarus"
	@echo "make formal         prove formal/*.mlw with $(WHY3_PROVER) (every goal must be Valid)"
	@echo "make formal-cvc4    informational CVC4 cross-check"
	@echo "make clean          remove $(BUILD)/"
	@echo "Needs: verilator >= 5, iverilog >= 12, why3 >= 1.6 with z3 (why3 config detect)"
