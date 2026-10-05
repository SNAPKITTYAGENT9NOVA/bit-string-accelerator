# Signoff report — tt_um_snapkittyagent9nova_bitacc

Hardened locally with the same tools and versions as `tt-gds-action@ttsky26d`.
The GDS has not been fabricated, and has not been through Tiny Tapeout's own
CI. That happens when the submission repository is pushed.

| | |
|---|---|
| Flow | LibreLane 3.0.14 (Nix), tt-support-tools `main` @ 01d5d28, sky130A @ 8afc834 (ciel) |
| Size | 2×2 tiles, die 75,602 µm², core 72,565 µm² |
| Cells | 4,821 standard cells (12,927 instances with fill and tap), 516 hold buffers |
| Utilization | 62.9% |
| Clock target | 20 ns (50 MHz); the UART divisor pins adapt to the board clock |
| Power (nominal, from STA) | 2.98 mW |

## Checks

| Check | Result |
|---|---|
| Magic DRC | 0 errors |
| Routing DRC | 0 errors |
| LVS (Netgen) | 0 errors, 0 device differences |
| Antenna | 0 violating nets, 0 violating pins |
| Setup, all 9 PVT corners | met; worst slack +1.95 ns (max_ss_100C_1v60), +10.12 ns at nom_tt |
| Hold, all 9 PVT corners | met; worst slack +0.105 ns (min_ff_n40C_1v95) |
| Tiny Tapeout precheck (KLayout 0.30.8, Magic 8.3.568 as pinned by the precheck) | **passed**: Magic DRC, KLayout FEOL/BEOL/off-grid/pin-label/zero-area, top macro name, forbidden layers, prBoundary, pins, n-well, Verilog syntax |
| Gate-level simulation of the powered post-layout netlist (`test/`, Icarus 12, sky130 cell models) | 2,183 checks, 0 failures |

## Known residuals

| Item | Count | Assessment |
|---|---|---|
| Max slew violations | 121 at nom_tt, 897 at max_ss, 11 at nom_ff | Nets driven by resizer-inserted fanout buffers (`clkdlybuf4s25_1`) reach ~1.0 ns transitions against a 0.75 ns limit. Setup and hold are met with these slews included, but delays beyond the library's characterized range are extrapolated. Excluding `clkdlybuf4s*` from repair made it worse (274 at nom_tt, 12 cap violations), so that run was discarded. |
| Max fanout violations | 33 | 32 are clock-tree leaf buffers driving 12 flip-flops against the generic limit of 10; one data net has fanout 11. |
| Max capacitance violations | 3 (max_ss), 2 (nom_ss), 0 at tt/ff | Slow corners only. |
| Disconnected pins | 9 | `uio_in[7:0]` and `ena`, which the design does not use (0 connections in the netlist). |
| Floating nets during repair | 2 | `VPWR`/`VGND` before power connection. |

Tiny Tapeout's precheck does not gate on slew, fanout or capacitance; they are
reported here because they affect timing accuracy, not functionality.

## Reproduce

See [`README.md`](README.md), "Hardening locally". The run produced
`runs/wokwi/final/` and `tt_submission/`; neither is committed (Tiny Tapeout's
action regenerates them).
