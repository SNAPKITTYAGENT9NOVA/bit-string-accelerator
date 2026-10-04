IVERILOG ?= iverilog
VVP ?= vvp
WHY3 ?= why3

all: sim formal

sim:
	$(IVERILOG) -g2012 -o simv rtl/bit_accelerator.sv verification/tb_bit_accelerator.sv
	$(VVP) simv

formal:
	$(WHY3) prove formal/bit_address.mlw
	$(WHY3) prove formal/bit_extract.mlw

clean:
	rm -f simv
