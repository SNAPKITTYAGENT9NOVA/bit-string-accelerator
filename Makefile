# bit-string-accelerator: build and verification entry points.
#
#   make test      everything below (what CI runs)
#   make lint      verilator -Wall on rtl/bit_accelerator.sv
#   make sim       self-checking testbench under Icarus and Verilator
#   make formal    Why3 proofs in formal/ (every goal must be proved by Z3)
#   make spice     ngspice timing model, fails if the delay is not measured
#   make accel     the bit_accelerator/ v2 design (lint, sim, formal)
#   make gpu       the Rust OpenCL crate in gpu/ (fmt, clippy, tests)
#   make fpga      FPGA wrapper: lint, UART testbench, host co-simulation, bitstreams
#   make fpga-gl   FPGA wrapper on post-synthesis netlists (slow, ~10 min)
#   make asic      sky130 synthesis + proof that the netlist equals the RTL

IVERILOG    ?= iverilog
VVP         ?= vvp
VERILATOR   ?= verilator
NGSPICE     ?= ngspice
WHY3_PROVER ?= z3
WHY3_TIME   ?= 30
BUILD       ?= build
SEED        ?= 1
OPS         ?= 2000

RTL     := rtl/bit_accelerator.sv
TB      := verification/tb_bit_accelerator.sv
FORMAL  := formal/bit_address.mlw formal/bit_extract.mlw
PROVE   := bit_accelerator/scripts/prove.sh

.PHONY: all test lint sim sim-icarus sim-verilator formal spice accel gpu fpga fpga-gl asic clean
.DEFAULT_GOAL := test

all test: lint sim formal spice accel gpu fpga asic

lint:
	$(VERILATOR) --lint-only -Wall $(RTL)

sim: sim-icarus sim-verilator

sim-icarus:
	mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb.vvp $(RTL) $(TB)
	$(VVP) -n $(BUILD)/tb.vvp +seed=$(SEED) +ops=$(OPS)

sim-verilator:
	mkdir -p $(BUILD)/verilator
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-lint --top-module tb_bit_accelerator \
	  -Mdir $(BUILD)/verilator $(RTL) $(TB) >/dev/null
	$(BUILD)/verilator/Vtb_bit_accelerator +seed=$(SEED) +ops=$(OPS)

formal:
	$(PROVE) -P $(WHY3_PROVER) -t $(WHY3_TIME) $(FORMAL)

spice:
	mkdir -p $(BUILD)
	$(NGSPICE) -b spice/bit_extract.sp > $(BUILD)/spice.log 2>&1
	@grep -E '^tpd *= *[0-9.e+-]+' $(BUILD)/spice.log || { cat $(BUILD)/spice.log; echo "tpd not measured"; exit 1; }

accel:
	$(MAKE) -C bit_accelerator test

gpu:
	cd gpu && cargo fmt --check
	cd gpu && cargo clippy --all-targets -- -D warnings
	# Serial: PoCL 5.0 can abort when several contexts are released concurrently.
	cd gpu && RUST_TEST_THREADS=1 cargo test

fpga:
	$(MAKE) -C fpga lint sim cosim icebreaker ulx3s

fpga-gl:
	$(MAKE) -C fpga gl-sim

asic:
	$(MAKE) -C asic all

clean:
	rm -rf $(BUILD) simv
	$(MAKE) -C bit_accelerator clean
	$(MAKE) -C fpga clean
	$(MAKE) -C asic clean
	cd gpu && cargo clean
