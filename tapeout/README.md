# Tiny Tapeout submission

This directory is a complete [Tiny Tapeout](https://tinytapeout.com) project for
the **ttsky26d** shuttle (SkyWater sky130A). It is laid out like Tiny Tapeout's
`ttsky-verilog-template` repository, so its contents can be pushed as the root
of the submission repository unchanged.

| | |
|---|---|
| Top module | `tt_um_snapkittyagent9nova_bitacc` |
| Size | 2×2 tiles |
| Design | `bit_accelerator` core + 4 × 64-bit RAM + UART (`src/`) |
| Datasheet | [`docs/info.md`](docs/info.md) |
| Flow | LibreLane 3.0.14 + tt-support-tools, the versions `tt-gds-action@ttsky26d` uses |

`src/bit_accelerator.sv`, `src/uart_rx.sv`, `src/uart_tx.sv` and
`test/tb_fpga_top.sv` are copies of `../rtl/` and `../fpga/` sources.
`make check-sync` (run by the monorepo CI) fails if they drift; `make sync`
refreshes them.

## Results

See [`SIGNOFF.md`](SIGNOFF.md) for the hardened layout: DRC, LVS, antenna,
timing, utilization and gate-level simulation.

## Testing

`make test` runs the shared UART testbench (`test/tb_fpga_top.sv`) on the RTL
twice: with divisor pins d = 2, and with the default divisor (all pins low).
The testbench is plain SystemVerilog under Icarus Verilog. It writes
`results.xml`, which is what Tiny Tapeout's gate-level action checks, so no
cocotb or Python is involved. `make gl-test` runs the same testbench on the
post-layout netlist.

The host tool also passes its acceptance test against this top level through a
pseudo-terminal (`../fpga/sim/uart_pty.cpp` built with `-DTT_TOP`):
`bitacc --words 4 selftest 3000` reports 0 mismatches.

## Hardening locally

Tiny Tapeout's action runs LibreLane in Docker. Without Docker, use LibreLane's
Nix shell:

```sh
git clone -b 3.0.14 https://github.com/librelane/librelane && cd librelane
nix develop          # OpenROAD, Magic, KLayout, Netgen, Yosys, LibreLane 3.0.14
cd <submission repo> && make harden
```

`tt_tool.py` expects to run from the root of a git repository with a remote,
which the submission repository is.

## Submitting (owner's steps)

Submitting creates a public repository under your account and buys silicon
area, so these steps are yours:

1. Create a repository from <https://github.com/TinyTapeout/ttsky-verilog-template>
   (for example `tt-bit-string-accelerator`). Replace its contents with this
   directory and push. Enable GitHub Pages (Settings → Pages → GitHub Actions).
2. Check that the `gds`, `test` and `docs` actions pass. `gds` runs hardening,
   precheck and the gate-level test on GitHub's runners.
3. Buy a 2×2 slot (4 tiles) on the ttsky26d shuttle at <https://app.tinytapeout.com> and
   submit the repository there before the shuttle's deadline.
4. When the chips arrive, test the design with a USB-UART adapter on
   `ui[3]`/`uo[4]` and `bitacc --words 4 selftest`. See `docs/info.md`.
