# Tiny Tapeout submission (ttsky26d, sky130A).
#
# This directory has the layout of a Tiny Tapeout project repository
# (info.yaml, src/, test/, docs/, .github/workflows/). src/ and test/ hold
# copies of shared sources so the directory can be pushed as its own repository.
#
#   make sync         copy the shared RTL and testbench into src/ and test/
#   make check-sync   fail if a copy differs from its original (CI runs this)
#   make test         UART testbench on the RTL (test/, divisor 2 and default)
#   make harden       GDS with LibreLane 3.0.14 via tt-support-tools (needs the
#                     LibreLane Nix shell; see README.md)
#   make gl-test      the same testbench on the hardened gate-level netlist

SHARED := ../rtl/bit_accelerator.sv:src/bit_accelerator.sv \
          ../fpga/rtl/uart_rx.sv:src/uart_rx.sv \
          ../fpga/rtl/uart_tx.sv:src/uart_tx.sv \
          ../fpga/tb/tb_fpga_top.sv:test/tb_fpga_top.sv

.PHONY: sync check-sync test harden gl-test clean

sync:
	@for p in $(SHARED); do cp $${p%%:*} $${p##*:}; echo "copied $${p%%:*} -> $${p##*:}"; done

check-sync:
	@for p in $(SHARED); do cmp -s $${p%%:*} $${p##*:} || { echo "$${p##*:} differs from $${p%%:*}; run make sync"; exit 1; }; done
	@echo "src/ and test/ match their originals"

test: check-sync
	$(MAKE) -C test
	$(MAKE) -C test TB_DEFINES=-DTT_DEFAULT_BAUD

TT_TOOLS ?= tt
TT_TOOLS_REF ?= main

$(TT_TOOLS):
	git clone --depth 1 -b $(TT_TOOLS_REF) https://github.com/TinyTapeout/tt-support-tools $@

harden: check-sync | $(TT_TOOLS)
	./$(TT_TOOLS)/tt_tool.py --create-user-config
	./$(TT_TOOLS)/tt_tool.py --harden --no-docker
	./$(TT_TOOLS)/tt_tool.py --print-stats
	./$(TT_TOOLS)/tt_tool.py --print-warnings

gl-test:
	cp runs/wokwi/final/nl/tt_um_snapkittyagent9nova_bitacc.nl.v test/gate_level_netlist.v
	$(MAKE) -C test GATES=yes

clean:
	rm -rf runs tt_submission src/user_config.json src/config_merged.json
	$(MAKE) -C test clean
