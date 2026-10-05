# Runs test/tb_fpga_top.sv (the shared UART testbench, Tiny Tapeout top mode)
# with Icarus Verilog and writes results.xml (JUnit) for the Tiny Tapeout
# gate-level test action. No cocotb or Python is needed.
#
#   make                 RTL simulation
#   make GATES=yes       gate-level simulation of gate_level_netlist.v
#                        (needs PDK_ROOT with sky130A installed)

SHELL := /bin/bash
SRC_DIR = $(abspath ../src)
PROJECT_SOURCES = bit_accelerator.sv uart_rx.sv uart_tx.sv tt_um_snapkittyagent9nova_bitacc.sv
TB_DEFINES ?=
IVERILOG ?= iverilog
VVP ?= vvp

ifneq ($(GATES),yes)
SIM_BUILD = sim_build/rtl
SOURCES   = $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
DEFINES   = -DTT_TOP $(TB_DEFINES)
else
SIM_BUILD = sim_build/gl
PDK ?= sky130A
SOURCES   = $(PDK_ROOT)/$(PDK)/libs.ref/sky130_fd_sc_hd/verilog/primitives.v \
            $(PDK_ROOT)/$(PDK)/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v \
            $(abspath gate_level_netlist.v)
DEFINES   = -DTT_TOP -DGL_TEST -DGATE_LEVEL -DFUNCTIONAL -DUSE_POWER_PINS -DSIM -DUNIT_DELAY=\#1 $(TB_DEFINES)
endif

.PHONY: all clean
all:
	mkdir -p $(SIM_BUILD)
	rm -f results.xml
	$(IVERILOG) -g2012 $(DEFINES) -o $(SIM_BUILD)/tb.vvp $(SOURCES) tb_fpga_top.sv
	@set -o pipefail; $(VVP) -n $(SIM_BUILD)/tb.vvp | tee $(SIM_BUILD)/sim.log; rc=$$?; \
	  name=$$(if [ "$(GATES)" = yes ]; then echo gate_level; else echo rtl; fi)$(TB_DEFINES); \
	  checks=$$(grep -oE 'checks=[0-9]+ fails=[0-9]+' $(SIM_BUILD)/sim.log | tail -1); \
	  if [ $$rc -eq 0 ] && grep -q '^PASS:' $(SIM_BUILD)/sim.log; then \
	    printf '<testsuites><testsuite name="tb_fpga_top" tests="1" failures="0"><testcase name="%s"><system-out>%s</system-out></testcase></testsuite></testsuites>\n' "$$name" "$$checks" > results.xml; \
	  else \
	    printf '<testsuites><testsuite name="tb_fpga_top" tests="1" failures="1"><testcase name="%s"><failure message="%s"/></testcase></testsuite></testsuites>\n' "$$name" "$$checks" > results.xml; \
	    exit 1; \
	  fi

clean:
	rm -rf sim_build results.xml
