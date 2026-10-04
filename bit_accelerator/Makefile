# Bit Accelerator Build System
# Complete build and verification workflow

.PHONY: all clean rtl sim verify formal spice test

# Tool configuration
VERILATOR = verilator
VERILATOR_FLAGS = --cc --exe --build -j 4
WY3 = why3
WY3_FLAGS = prove --timeout 10 --steps 100000

# Directories
RTL_DIR = rtl
TB_DIR = testbenches
FORMAL_DIR = formal
SIM_DIR = sim
SPICE_DIR = spice
OBJ_DIR = obj_dir

# Source files
RTL_SOURCES = \
	$(RTL_DIR)/bit_accelerator_pkg.sv \
	$(RTL_DIR)/bit_address_generator.sv \
	$(RTL_DIR)/bit_extractor.sv \
	$(RTL_DIR)/bit_modifier.sv \
	$(RTL_DIR)/behavioral_memory.sv \
	$(RTL_DIR)/bit_accelerator.sv

TB_SOURCES = $(TB_DIR)/tb_bit_accelerator.sv

FORMAL_SOURCES = \
	$(FORMAL_DIR)/bit_addressing.why3 \
	$(FORMAL_DIR)/bit_addressing_proofs.why3

# Targets
all: rtl sim test formal

# RTL Lint and Check
rtl:
	@echo "=== Checking RTL Syntax ==="
	$(VERILATOR) --lint-only -Wall $(RTL_SOURCES)
	@echo "✓ RTL syntax check passed"

# Simulation
sim: $(OBJ_DIR)/Vbit_accelerator
	@echo "=== Building Testbench ==="
	$(OBJ_DIR)/Vbit_accelerator
	@echo "✓ Simulation completed"

$(OBJ_DIR)/Vbit_accelerator: $(RTL_SOURCES) $(TB_SOURCES)
	@echo "=== Compiling with Verilator ==="
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_bit_accelerator \
		--Mdir $(OBJ_DIR) \
		$(RTL_SOURCES) $(TB_SOURCES)

# Test execution
test: sim
	@echo "=== Functional Verification ==="
	@echo "Running testbench..."
	@$(OBJ_DIR)/Vbit_accelerator

# Formal Verification with Why3
formal:
	@echo "=== Formal Verification with Why3 ==="
	@for file in $(FORMAL_SOURCES); do \
		echo "Verifying $$file..."; \
		$(WY3) $(WY3_FLAGS) $$file || exit 1; \
	done
	@echo "✓ All formal proofs verified"

# Clean
clean:
	@echo "=== Cleaning Build Artifacts ==="
	rm -rf $(OBJ_DIR)
	rm -f $(SIM_DIR)/*.vcd
	rm -f $(SIM_DIR)/*.out
	@echo "✓ Cleanup complete"

# Help
help:
	@echo "Bit Accelerator Build System"
	@echo "============================"
	@echo ""
	@echo "Targets:"
	@echo "  make all      - Build RTL, simulate, and verify (full workflow)"
	@echo "  make rtl      - Check RTL syntax"
	@echo "  make sim      - Compile and run simulation"
	@echo "  make test     - Run functional tests"
	@echo "  make formal   - Run formal verification with Why3"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make help     - Show this help message"
	@echo ""
	@echo "Tools Required:"
	@echo "  - Verilator (open-source Verilog simulator)"
	@echo "  - Why3 (formal verification platform)"
	@echo ""

# Default target
.DEFAULT_GOAL := help
