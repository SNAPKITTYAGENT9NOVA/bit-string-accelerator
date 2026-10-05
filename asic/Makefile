# ASIC synthesis of rtl/bit_accelerator.sv to the SkyWater sky130 high-density
# standard cells (sky130_fd_sc_hd, typical corner 25 C / 1.80 V).
#
#   make synth    Yosys + ABC (buffering and gate sizing)  -> build/bit_accelerator_sky130.v
#   make equiv    prove the gate netlist equivalent to the RTL (Yosys equiv_*)
#   make sta      OpenSTA at PERIOD ns (needs `sta` on PATH or STA=/path/to/sta)
#   make all      synth + equiv
#
# Pre-layout only: no floorplan, placement, clock tree or wire parasitics.

YOSYS  ?= yosys
STA    ?= sta
PERIOD ?= 2.0
BUILD  ?= build

ORFS_COMMIT := 2aeb23bcc3b5aa925abb991c4347ce73827b8b82
LIB_URL     := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/$(ORFS_COMMIT)/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
LIB_SHA256  := ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9
LIB         := $(BUILD)/sky130_fd_sc_hd__tt_025C_1v80.lib
RTL         := ../rtl/bit_accelerator.sv
NETLIST     := $(BUILD)/bit_accelerator_sky130.v

.PHONY: all synth equiv sta clean
.DEFAULT_GOAL := all

all: synth equiv

$(LIB):
	mkdir -p $(BUILD)
	curl -sSfL -o $@.tmp $(LIB_URL)
	echo "$(LIB_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

synth: $(NETLIST)

# -nofsm keeps the RTL state encoding so the equivalence check can match registers.
$(NETLIST): $(RTL) $(LIB) abc.script
	$(YOSYS) -q -l $(BUILD)/synth.log -p "read_verilog -sv $(RTL); \
	  synth -nofsm -flatten -top bit_accelerator; \
	  dfflibmap -liberty $(LIB); \
	  abc -liberty $(LIB) -D 2000 -script abc.script; \
	  opt_clean; tee -o $(BUILD)/area.rpt stat -liberty $(LIB); \
	  write_verilog -noattr -noexpr $@" 2>&1 | grep -v "unsupported expression" || true
	@test -s $@
	@grep -E "Number of cells:|Chip area" $(BUILD)/area.rpt

equiv: $(NETLIST)
	$(YOSYS) -q -l $(BUILD)/equiv.log -p " \
	  read_verilog -sv $(RTL); prep -flatten -top bit_accelerator; \
	  rename bit_accelerator gold; design -stash gold; \
	  read_liberty -ignore_miss_func $(LIB); read_verilog $(NETLIST); \
	  hierarchy -top bit_accelerator; flatten; rename bit_accelerator gate; design -stash gate; \
	  design -copy-from gold -as gold gold; design -copy-from gate -as gate gate; \
	  equiv_make gold gate equiv; hierarchy -top equiv; async2sync; \
	  equiv_simple -seq 5; equiv_induct -seq 5; equiv_status -assert" 2>&1 | grep -v "unsupported expression" || true
	@grep -q "Equivalence successfully proven" $(BUILD)/equiv.log
	@grep -E "proven and" $(BUILD)/equiv.log | tail -1

sta: $(NETLIST)
	LIB=$(LIB) NETLIST=$(NETLIST) PERIOD=$(PERIOD) $(STA) -no_init -exit sta.tcl | tee $(BUILD)/sta_$(PERIOD)ns.rpt
	@! grep -q VIOLATED $(BUILD)/sta_$(PERIOD)ns.rpt

clean:
	rm -rf $(BUILD)
