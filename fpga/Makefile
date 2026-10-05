# FPGA build for the bit-string accelerator.
#
#   make sim          UART-level testbench on the RTL (Icarus + Verilator)
#   make lint         verilator -Wall on both board tops
#   make icebreaker   bitstream for iCEBreaker (iCE40UP5K)  -> build/icebreaker.bin
#   make ulx3s        bitstream for ULX3S (ECP5 25F)        -> build/ulx3s.bit
#   make gl-sim       testbench on post-synthesis netlists (iCE40, ECP5)
#   make cosim        host tool (host/) against the RTL through a pseudo-terminal
#   make prog-icebreaker / prog-ulx3s   program a connected board
#   make all          lint, sim, cosim, gl-sim and both bitstreams
#
# Tools: yosys, nextpnr-ice40, nextpnr-ecp5, icepack (icestorm), ecppack
# (prjtrellis), iverilog, verilator; iceprog / openFPGALoader to program.

YOSYS     ?= yosys
IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator
BUILD     ?= build
SEED      ?= 1
ULX3S_DEVICE ?= 25k          # 12k, 25k, 45k or 85k to match the board
YOSYS_DAT ?= /usr/share/yosys   # Yosys data dir with ice40/ and ecp5/ cell models

CORE := ../rtl/bit_accelerator.sv rtl/uart_rx.sv rtl/uart_tx.sv rtl/word_memory.sv rtl/fpga_top.sv
TB   := tb/tb_fpga_top.sv

.PHONY: all sim sim-icarus sim-verilator lint icebreaker ulx3s gl-sim gl-sim-ice40 gl-sim-ecp5 \
        cosim host prog-icebreaker prog-ulx3s clean
.DEFAULT_GOAL := all

all: lint sim cosim gl-sim icebreaker ulx3s

$(BUILD):
	mkdir -p $@

# ------------------------------------------------------------------ RTL checks
sim: sim-icarus sim-verilator

sim-icarus: | $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/tb_fpga.vvp $(CORE) $(TB)
	$(VVP) -n $(BUILD)/tb_fpga.vvp

sim-verilator: | $(BUILD)
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-lint --top-module tb_fpga_top \
	  -Mdir $(BUILD)/verilator $(CORE) $(TB) >/dev/null
	$(BUILD)/verilator/Vtb_fpga_top

lint:
	$(VERILATOR) --lint-only -Wall $(CORE) rtl/power_on_reset.sv boards/icebreaker_top.sv --top-module icebreaker_top
	$(VERILATOR) --lint-only -Wall $(CORE) rtl/power_on_reset.sv boards/ulx3s_top.sv --top-module ulx3s_top

# ------------------------------------------------------------------ host tool
host:
	cd host && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test

cosim: host
	BUILD=$(BUILD) sim/cosim.sh 2000 1

# ------------------------------------------------------------------ iCEBreaker
icebreaker: $(BUILD)/icebreaker.bin

$(BUILD)/icebreaker.json: $(CORE) rtl/power_on_reset.sv boards/icebreaker_top.sv | $(BUILD)
	$(YOSYS) -q -l $(BUILD)/icebreaker_synth.log -p "read_verilog -sv $^; synth_ice40 -top icebreaker_top -json $@"

$(BUILD)/icebreaker.asc: $(BUILD)/icebreaker.json boards/icebreaker.pcf
	nextpnr-ice40 --up5k --package sg48 --json $< --pcf boards/icebreaker.pcf --asc $@ \
	  --freq 12 --seed $(SEED) -l $(BUILD)/icebreaker_pnr.log -q

$(BUILD)/icebreaker.bin: $(BUILD)/icebreaker.asc
	icepack $< $@
	@grep -E "Max frequency|ICESTORM_LC:|ICESTORM_RAM:" $(BUILD)/icebreaker_pnr.log | tail -3

prog-icebreaker: $(BUILD)/icebreaker.bin
	iceprog $<

# ------------------------------------------------------------------ ULX3S
ulx3s: $(BUILD)/ulx3s.bit

$(BUILD)/ulx3s.json: $(CORE) rtl/power_on_reset.sv boards/ulx3s_top.sv | $(BUILD)
	$(YOSYS) -q -l $(BUILD)/ulx3s_synth.log -p "read_verilog -sv $^; synth_ecp5 -top ulx3s_top -json $@"

$(BUILD)/ulx3s.config: $(BUILD)/ulx3s.json boards/ulx3s.lpf
	nextpnr-ecp5 --$(strip $(ULX3S_DEVICE)) --package CABGA381 --json $< --lpf boards/ulx3s.lpf \
	  --textcfg $@ --seed $(SEED) -l $(BUILD)/ulx3s_pnr.log -q

$(BUILD)/ulx3s.bit: $(BUILD)/ulx3s.config
	ecppack --compress $< $@
	@grep -E "Max frequency|TRELLIS_COMB:|DP16KD:" $(BUILD)/ulx3s_pnr.log | tail -3

prog-ulx3s: $(BUILD)/ulx3s.bit
	openFPGALoader --board ulx3s $<

# ------------------------------------------------------------------ gate level
# The netlists are built with CLKS_PER_BIT = 8 so the UART testbench runs fast.
gl-sim: gl-sim-ice40 gl-sim-ecp5

gl-sim-ice40: | $(BUILD)
	$(YOSYS) -q -p "read_verilog -sv $(CORE); chparam -set CLKS_PER_BIT 8 fpga_top; \
	  synth_ice40 -top fpga_top; write_verilog -noattr $(BUILD)/fpga_top_ice40_gl.v"
	$(IVERILOG) -g2012 -DGATE_LEVEL -o $(BUILD)/gl_ice40.vvp \
	  $(BUILD)/fpga_top_ice40_gl.v $(strip $(YOSYS_DAT))/ice40/cells_sim.v $(TB)
	$(VVP) -n $(BUILD)/gl_ice40.vvp

# Yosys ships DP16KD (ECP5 block RAM) only as a black box, so this netlist
# keeps the memory in LUT RAM (-nobram); everything else is the real mapping.
gl-sim-ecp5: | $(BUILD)
	$(YOSYS) -q -p "read_verilog -sv $(CORE); chparam -set CLKS_PER_BIT 8 fpga_top; \
	  synth_ecp5 -nobram -top fpga_top; write_verilog -noattr $(BUILD)/fpga_top_ecp5_gl.v"
	$(IVERILOG) -g2012 -DGATE_LEVEL -I$(strip $(YOSYS_DAT))/ecp5 -o $(BUILD)/gl_ecp5.vvp \
	  $(BUILD)/fpga_top_ecp5_gl.v $(strip $(YOSYS_DAT))/ecp5/cells_sim.v $(TB)
	$(VVP) -n $(BUILD)/gl_ecp5.vvp

clean:
	rm -rf $(BUILD)
	cd host && cargo clean
