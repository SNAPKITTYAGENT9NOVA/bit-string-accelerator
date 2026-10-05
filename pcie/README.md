# PCIe accelerator (LiteFury)

The parallel version of the bit accelerator, attached to a host over PCIe.
`rtl/bit_accelerator.sv` is the golden functional reference, and the
parallel engine must produce identical results.

```
host RAM ──DMA reader──▶ descriptors ─▶ dispatch ─▶ lane 0 … lane N-1 ─▶ reorder buffer ─▶ results ──DMA writer──▶ host RAM
                         (128-bit)        (word w → lane w mod N)        (descriptor order)  (16 per beat)
CSRs (BAR0): word access to the bit store, status, counters, geometry
```

| Path | Contents |
|---|---|
| `rtl/bitacc_engine.sv` | N lanes, each owning one memory bank; reorder buffer; host word port |
| `rtl/bitacc_pcie_core.sv` | 128-bit descriptor/result streams, result packing, register interface |
| `tb/tb_engine.sv` | engine vs the reference core |
| `tb/tb_pcie_core.sv` | PCIe core vs the reference core |
| `litex/bitacc_litefury.py` | LiteX SoC: LitePCIe Gen2 x4, one DMA channel, CSRs, DDR3 controller |
| `host/bitacc_pcie.c` | Linux host program (`info`, `selftest`) on the generated liblitepcie |
| `host/sim/mock_litepcie.cpp` | liblitepcie stand-in backed by the Verilated core, for co-simulation |

## Why the results equal the reference

Word `w` lives in lane `w mod N`, so every operation on a word runs in one
lane, in arrival order. Operations on different words touch disjoint state
and commute. Errors (address outside the bit store, opcodes 5–7) never
write. So the final memory and every result equal executing the stream one
operation at a time. The reorder buffer returns results in descriptor order.

This argument is backed by testing, not a formal proof.
`tb/tb_engine.sv` runs both designs on the same random stream:
- hot-spot bursts that queue in one lane while others overtake them;
- random, past-the-end and 64-bit-wrapping addresses, and undefined opcodes;
- input gaps, and result backpressure with stalls long enough to fill the reorder buffer.

It compares every result and every final memory word. It also fails unless
out-of-order completion, a full reorder buffer and every operation class
actually occurred. Results:

| Check | Result |
|---|---|
| Engine, 2×4, 4×16, 8×16, 8×512 lanes × words, seeds 1 and 7 (Icarus) | 0 mismatches; 993–1,307 out-of-order completions per 4,000 operations |
| Engine under Verilator | 0 mismatches |
| PCIe core, 3,200 descriptors (Icarus) | 9,250 checks, 0 failures |
| Host program against the Verilated core (`make cosim`) | 200,000 + 50,000 operations, 0 mismatches |
| Injected faults, engine | 8/8 detected (lane hazard, reorder, range check, SET, host read timing, reorder overfill, lane select, bit select) |
| Injected faults, PCIe core | 7/7 detected (byte order, beat size, opcode bits, address bits, error/bit swap, counter, packer overwrite) |
| Injected faults, host co-simulation | engine SET bug and result byte reversal both detected |
| Lint | `verilator -Wall` clean |

Three testbench bugs were found and fixed on the way. Each one had hidden
missing coverage:
- **Static stimulus variable:** a variable initialized in its declaration
  inside a loop is static in Icarus, so the stimulus mix was not what it
  claimed to be.
- **Overcounting coverage metric:** an out-of-order counter that also counted
  results waiting behind backpressure.
- **Stalls hidden by idle:** a watchdog that reset whenever the core was idle,
  so a design that lost results simply hung.

## Build

```sh
make lint sim sim-verilator     # RTL checks
make soc                        # LiteX sources + Linux driver (needs LiteX, no Vivado)
make cosim                      # host program against the Verilated core
make bitstream                  # needs Vivado (free edition covers the XC7A100T)
```

On the NUC, load the kernel driver from the generated
`build/litefury/driver/kernel`, then build and run the host program:

```sh
make -C host LITEPCIE=../build/litefury/driver
./host/bitacc_pcie info
./host/bitacc_pcie selftest 10000000
```

LiteX supports the LiteFury as the SQRL Acorn CLE-101, which litex-boards
documents as equivalent (`litex_boards/platforms/sqrl_acorn.py`). The same
bitstream works in the NUC's M.2 Key-M slot. It also works behind a USB4/
Thunderbolt enclosure that tunnels PCIe; nothing in the design depends on the
transport. I expect, but have not verified, that an ASM2464PD-based M.2
enclosure presents the card as a normal PCIe device in USB4/TB mode. It is
NVMe-only in USB 3 mode.

## Resources (estimate)

Yosys `synth_xilinx` for the engine and PCIe core at 8 lanes × 2,048 words
(128 KiB bit store): about 3,330 LUTs, 860 flip-flops and 32 RAMB36. On the
XC7A100T (63,400 LUTs, 135 RAMB36) that is about 5% of LUTs and 24% of block
RAM, before LitePCIe and the DDR3 controller. Timing closure at 125 MHz has
not been checked; that needs Vivado.

## Performance: what to expect

None of this has run on hardware, so these are ceilings derived from the
design and the link, not measurements:

- The engine accepts 1 descriptor per cycle: 125 M/s at 125 MHz. With 8 lanes
  at one operation per 2 cycles each, the lanes are not the limit.
- PCIe Gen2 x4 carries about 2 GB/s raw. With 16-byte descriptors that is at
  most about 100–125 M descriptors/s, before DMA and protocol overhead.

So the ceiling is on the order of 100 M single-bit operations per second. A
NUC core doing the same operations on a bitmap that fits in its cache is
faster than that. **For single-bit operations, this card will not beat the
CPU.** What it does establish is the system path the roadmap needs:
descriptor DMA, the work queue, parallel lanes, ordered results, a host
driver, and identical results to the reference.

To get a real speedup, each descriptor has to carry much more work than one
bit, so the link stops being the limit. Examples are operations over ranges
of the bit store: popcount/rank, AND/OR/XOR of bitmap regions, find-first-set,
and bit-parallel pattern matching. Those keep the lanes busy for many cycles
per 16-byte descriptor. That is the next design step.

## Generated-code note

LiteX's generated `liblitepcie/litepcie_dma.c` (at the LiteX revision used
here) checks `if (poll < 0)` instead of the return value of `poll()`, so poll
errors are ignored. The host program builds that file as shipped, without
`-Werror`.
