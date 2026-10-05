# ASIC synthesis (sky130)

Synthesizes `rtl/bit_accelerator.sv` to the SkyWater 130 nm high-density standard
cells (`sky130_fd_sc_hd`, typical corner, 25 °C, 1.80 V). The liberty file is
downloaded from OpenROAD-flow-scripts at a pinned commit and checked by SHA-256.

```sh
make            # synth + equiv
make sta STA=/path/to/sta PERIOD=2.0
```

Needs Yosys. `make sta` needs [OpenSTA](https://github.com/The-OpenROAD-Project/OpenSTA)
(build it from source with CUDD; it is not packaged for Ubuntu).

## Results

| | |
|---|---|
| Cells | 1538 (139 flip-flops, plus buffers inserted for fanout) |
| Cell area | 10,063 µm² (about 0.010 mm²) |
| Equivalence to RTL | proved: 223/223 `$equiv` points (Yosys `equiv_simple` + `equiv_induct`) |
| Timing, 2.0 ns (500 MHz) | met: WNS 0.00 ns, no slew/capacitance/fanout violations |
| Timing, 1.9 ns | fails: WNS -0.03 ns |

These are **pre-layout** numbers: no floorplan, placement, clock tree or wire
parasitics. Inputs are assumed registered on the same clock. Post-layout Fmax
will be lower. Getting to a GDS for fabrication (OpenLane or
OpenROAD-flow-scripts, then a shuttle) is not done here.

Synthesis uses `-nofsm` so the gate netlist keeps the RTL state encoding, which
lets the equivalence check match registers. With FSM re-encoding, Yosys could
not prove 135 of 220 points without a sequential proof across encodings.
