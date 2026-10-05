# Pre-layout static timing for the sky130 netlist (OpenSTA).
# Environment: LIB (liberty), NETLIST (gate-level Verilog), PERIOD (ns).
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design bit_accelerator
create_clock -name clk -period $::env(PERIOD) [get_ports clk]
# Inputs come from, and outputs go to, registers on the same clock.
set_input_delay 0 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 0 -clock clk [all_outputs]
set_input_transition 0.1 [all_inputs]
set_load 0.005 [all_outputs]
report_checks -path_delay max -digits 3
report_check_types -max_slew -max_capacitance -max_fanout -violators
report_wns
report_tns
exit
