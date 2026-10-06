# PCIe accelerator (LiteFury)

The parallel version of the bit accelerator, attached to a host over PCIe.
`rtl/bit_accelerator.sv` is the golden functional reference, and the
parallel engine must produce identical results.

```
host RAM ──DMA reader──▶ descriptors ─▶ dispatch ─┬▶ lane 0 … lane N-1 ─┬▶ reorder buffer ─▶ results ──DMA writer──▶ host RAM
                         (128-bit)                 │ (word w → lane w mod N)│  (descriptor order)  (64-bit, 2 per beat)
                                                   └▶ range unit ──────────┘
                                                      (all lanes at once)
CSRs (BAR0): word access to the bit store, status, counters, geometry, format version, features
```

| Path | Contents |
|---|---|
| `rtl/bitacc_engine.sv` | N lanes, each owning one memory bank; range unit with pattern matcher; reorder buffer; host word port |
| `rtl/bitacc_pcie_core.sv` | 128-bit descriptor/result streams, result packing, register interface |
| `tb/gold_ops.svh` | reference semantics of every operation, executed on the reference core |
| `tb/range_stim.svh` | random range-operation stimulus and coverage goals |
| `tb/tb_engine.sv` | engine vs the reference core |
| `tb/tb_pcie_core.sv` | PCIe core vs the reference core |
| `../formal/lane_map.mlw` | Why3 proof of the BULK lane-mapping arithmetic |
| `litex/bitacc_litefury.py` | LiteX SoC: LitePCIe Gen2 x4, one DMA channel, CSRs, DDR3 controller |
| `host/bitacc_pcie.c` | Linux host program (`info`, `selftest`, `bench`) on the generated liblitepcie |
| `host/sim/mock_litepcie.cpp` | liblitepcie stand-in backed by the Verilated core, for co-simulation |
| `host/cpu_bench.c` | the same work on the host CPU, for comparison (`make -C host cpu_bench`) |
| `timing/` | open-source place and route for the XC7A100T: wrapper, pins, `run.sh` |

## Operations

One 16-byte descriptor per operation (format version 3, readable from the
`version` CSR; the `features` CSR says whether the MATCH unit is built in,
and with how many units):

| Bits | Field |
|---|---|
| `[63:0]` | `a`: bit address (single-bit and bit-range operations), or destination word (BULK) |
| `[67:64]` | opcode |
| `[68]` | `dry`: BULK computes and counts without writing |
| `[71:69]` | `fn`: BULK function; MATCH result kind |
| `[103:72]` | `len`: range length in bits, or in words for BULK |
| `[127:104]` | `src`: source word (BULK); pattern word (MATCH, mask in `src + 1`) |

| Opcode | Operation | Result value | Result bit |
|---|---|---|---|
| 0 GET, 1 TEST | read bit `a` | 0 | the bit |
| 2 SET, 3 CLEAR, 4 TOGGLE | write bit `a` | 0 | the new bit |
| 8 COUNT | count set bits in `[a, a+len)` | the count | count ≠ 0 |
| 9 FIND1, 10 FIND0 | first set / clear bit in `[a, a+len)` | its index (0 if none) | found |
| 11 SETR, 12 CLEARR, 13 FLIPR | set / clear / invert every bit of `[a, a+len)` | set bits before the operation | value ≠ 0 |
| 14 BULK | `dst[k] = fn(dst[k], src[k])` for words `k < len`; fn 0 COPY, 1 AND, 2 OR, 3 XOR, 4 ANDN (`dst & ~src`) | set bits in the results | value ≠ 0 |
| 15 MATCH | find the 64-bit pattern (word `src`) under its mask (word `src + 1`) at every bit position of `[a, a+len)` | fn 0: number of matches; fn 1: first matching position (0 if none) | fn 0: value ≠ 0; fn 1: found |
| 5–7 | undefined | error | |

A position `s` matches when every mask bit `j` lies inside the range
(`s + j < a + len`) and `bit(s + j) == pattern[j]`. The mask can be any
64-bit value: a run of low bits is a pattern of that length, and other masks
give patterns with gaps. A zero mask matches every position. The host writes
the pattern and mask words like any other data (word writes, or SETR/CLEARR
and BULK COPY in the descriptor stream).

One 8-byte result per descriptor, in descriptor order:
`[7:0] = 0xA0 | error << 1 | bit` (the UART builds' status byte), `[63:8] = value`.

These are errors, with no write and a result of bit 0, value 0:
- A single-bit address outside the store.
- A bit range with `a + len > words × 64`, including 64-bit wrap.
- A BULK region outside the store.
- A BULK with partially overlapping regions. Identical regions are allowed.
- BULK with `fn > 4`; MATCH with `fn > 1`, with `src + 2 > words`, or on a
  build without the MATCH unit.
- An undefined opcode.

`len = 0` is valid: the value is 0 and FIND and MATCH find nothing.

Each range descriptor does up to a whole bit store's worth of work: 1 Mbit
at the default 8 lanes × 2,048 words. That is the point. Single-bit
descriptors are limited by the link, and range descriptors are not.

## Why the results equal the reference

**Single-bit operations.** Word `w` lives in lane `w mod N`, so every
operation on a word runs in one lane, in arrival order. Operations on
different words touch disjoint state and commute. Errors never write.

**Range operations.** A range operation is a barrier:
- It starts only when every earlier operation has completed in its lane.
- It runs on all lanes at once.
- Nothing after it dispatches until it has finished.

Inside a range operation every word is read once and written at most once.
BULK regions are either disjoint or identical, so no word is both a source
and a different destination. The final memory and every result therefore
equal executing the stream one operation at a time, and the reorder buffer
returns results in descriptor order.

**BULK lane mapping.** BULK pairs `dst + k` with `src + k`, which usually
live in different lanes. In step `j`:
- Lane `i` reads source element `j·N + ((i − src) mod N)`.
- Destination lane `m` takes its source word from lane `(m − delta) mod N`, where `delta = (dst − src) mod N`.

`formal/lane_map.mlw` proves the index identities this relies on, for any
`N > 0`: every element is read exactly once, by the lane that owns it, at
the right local address, and the rotation hands it to the lane that owns
its destination word. Why3 1.6 with Z3 proves all 58 goals. A deliberately
wrong rotation fails to prove.

**Range semantics are defined by the reference core.** The testbenches
execute every range operation as single-bit operations on
`rtl/bit_accelerator.sv` (`tb/gold_ops.svh`). For example, COUNT is GETs of
every bit, and BULK is GET src, GET dst, then SET or CLEAR dst for every
bit. MATCH GETs the 64 pattern bits, the 64 mask bits and every haystack bit,
then applies the match rule above. Which range operations are errors is a specification choice, and it is
cross-checked against the reference core: the core must reject the last bit
of every invalid non-empty bit range. The host program's model
(`host/bitacc_pcie.c`) is a second, independent word-level implementation,
checked against the RTL in co-simulation.

The argument above is backed by testing and by the lane-mapping proof. It
is not a formal proof of the whole engine.

## Verification

`tb/tb_engine.sv` runs the engine and the reference on the same random stream:
- Hot-spot bursts that queue in one lane while others overtake them.
- Random, past-the-end and 64-bit-wrapping addresses, and undefined opcodes.
- About 10% range operations in every class: short (word-crossing),
  multi-step, empty, ending exactly at the end of the store, past the end,
  wrapping, and whole-store.
- BULK with disjoint, identical, overlapping and out-of-range regions,
  every function, and dry runs.
- FIND over regions a fill just emptied.
- MATCH, with the mask built in the stream right before it (by CLEARR/SETR):
  - contiguous runs of mask bits;
  - zero masks;
  - two far-apart bits, so windows cross words;
  - a full mask whose pattern is a BULK COPY of a haystack word;
  - whatever the memory holds.

  Both result kinds and the error cases are covered.
- Input gaps, and result backpressure with stalls long enough to fill the
  reorder buffer.

It compares every result (error, bit and value) and every final memory
word. It fails unless all of these actually occurred:
- every class above;
- out-of-order completion and a full reorder buffer;
- both barrier directions: a range operation waiting for dispatched
  single-bit operations, and an operation waiting for a running range
  operation;
- FIND found and not found;
- MATCH with matches, with none, found, not found, and over several steps.

Coverage is counted from what was executed, not from the generator's intent.

| Check | Result |
|---|---|
| Engine, 2×4, 4×16, 8×16, 8×512 lanes × words, seeds 1 and 7, plus 16×8, a build without MATCH, and MATCH with fewer units than lanes (4 lanes/1 unit, 8 lanes/2 units); 4,000 operations each (Icarus) | 0 mismatches. 8,068–24,425 checks per run; up to 1.41 M reference-core operations per run. |
| Engine under Verilator | 0 mismatches, all coverage goals met |
| PCIe core, 3,200 descriptors including 469 range operations (Icarus) | 9,897 checks, 0 failures |
| Host program against the Verilated core (`make cosim`) | 200,704 descriptors (12,855 range, 1,732 valid MATCH) and 50,176 (27,821 range, 3,726 valid MATCH): 0 mismatches |
| Host program at the LiteFury geometry, 8×2,048 (`make perf`) | 20,480 descriptors (4,876 range, 676 valid MATCH): 0 mismatches; 16,384 words checked |
| Injected faults, range unit | 22/22 detected against the final testbench. Examples: mask edges, rotation direction, BULK bound and last step, src/dst base, barrier in either direction, FIND lane order and first hit, overlap check, dry run, ANDN, fills of partial words, counting after instead of before, range end bound, missing dst read, stale value on an error result. |
| Injected faults, MATCH and the pipelined front end | 18/18 detected: inverted compare, wrong neighbour lane, lost previous-step word, validity not shifted by a word, mask top bit ignored, last step missing, index not shifted, pattern and mask swapped, result kind ignored, pattern word bound, empty match range, pattern not awaited; skid buffer ignoring reorder space or overfilling, wrong skid slot, barrier counter, stale queue-full flag, write register not cleared |
| Injected faults, MATCH sub-steps (`MATCH_LANES` < `LANES`) | 6/6 detected: unit word ignoring the sub-step, mask ignoring it, result index ignoring it, group ending before its last sub-step, previous group's word from the wrong lane, sub-step counter not reset |
| Injected faults, PCIe core | 9/9 detected (result order in a beat, value position, error/bit swap, opcode bit 3, len and src fields, fn/dry fields, beat size, counter step) |
| Injected faults, host co-simulation | FIND lane order, BULK rotation and fill count all detected (780–9,386 mismatches) |
| Lane mapping (`formal/lane_map.mlw`) | 58/58 goals proved by Z3 |
| Lint | `verilator -Wall` clean, with and without MATCH, 2 to 16 lanes |

Problems found and fixed while building this:
- **MATCH compared the wrong way.** The first matcher reported matches
  where masked bits *differed*, `&((w ^ p) | ~m)` instead of
  `~|((w ^ p) & m)`. The reference model caught it on the first run.
- **The 65-bit end-address sum didn't wrap.** Casting the whole sum to 65
  bits widened `(base << 3) + offset` too, so the effective address no
  longer wrapped mod 2⁶⁴. Verilator's lint flagged it; `eff` is now an
  explicit 64-bit value.
- **An empty range returned a stale value.** One restructuring sent empty
  ranges straight to the result, skipping the state that clears the
  accumulator. I found it on review; every range now passes through that
  state.
- **Verilator 5.020 crashed the engine testbench** (illegal instruction).
  It splits the main initial block, a coroutine with a fork, across C++
  functions and drops the wait for the join. `--output-split-cfuncs 0`
  avoids it.
- From the previous round: the CI gate that didn't gate (vvp piped into
  grep), Verilator's degenerate seeded `$random`, and the result packer's
  stall every third cycle.

## Build

```sh
make lint                       # RTL lint
make -j8 sim sim-verilator      # equivalence runs (the 8x512 runs take ~6 minutes each)
make soc                        # LiteX sources + Linux driver (needs LiteX, no Vivado)
make cosim                      # host program against the Verilated core
make perf                       # cycle-level throughput at 8 lanes x 2048 words, with limits
make timing                     # open-source place and route (needs nextpnr-xilinx, see below)
make bitstream                  # needs Vivado (free edition covers the XC7A100T)
make -C host cpu_bench          # the same work on the host CPU
```

On the NUC, load the kernel driver from the generated
`build/litefury/driver/kernel`, then build and run the host program:

```sh
make -C host LITEPCIE=../build/litefury/driver
./host/bitacc_pcie info
./host/bitacc_pcie selftest 10000000 1 5     # operations, seed, % range operations
./host/bitacc_pcie bench match 100000        # also: get, count, find, xor
./host/cpu_bench                             # the NUC's CPU on the same work
```

The SoC leaves out the MATCH unit by default. `litex/bitacc_litefury.py --match`
includes it with 2 units; `--match-lanes N` changes the unit count. See
Resources for the sizes.

LiteX supports the LiteFury as the SQRL Acorn CLE-101, which litex-boards
documents as equivalent (`litex_boards/platforms/sqrl_acorn.py`). The same
bitstream works in the NUC's M.2 Key-M slot. It also works behind a USB4/
Thunderbolt enclosure that tunnels PCIe; nothing in the design depends on the
transport. I expect, but have not verified, that an ASM2464PD-based M.2
enclosure presents the card as a normal PCIe device in USB4/TB mode. It is
NVMe-only in USB 3 mode.

## Timing (open-source estimate)

Vivado is the tool that decides whether the design meets 125 MHz, and it
hasn't been run. As an early signal, `timing/` places and routes the engine
and PCIe core for the LiteFury's `xc7a100t-fgg484-2` with
**nextpnr-xilinx** (openXC7) and the Project X-Ray database. A
register-bounded wrapper (`timing/timing_top.sv`) stands in for LitePCIe;
LitePCIe itself isn't included.

Toolchain, built from source in this session:
- nextpnr-xilinx from `github.com/openXC7/nextpnr-xilinx`;
- the chip database exported with its `bbaexport.py` from `prjxray-db/artix7`.

Point `NEXTPNR` and `CHIPDB` at them and run `make timing`.

| Design | Fmax (nextpnr-xilinx) | LUTs (Yosys) | Flip-flops | RAMB36 |
|---|---|---|---|---|
| Before the timing work (range operations only) | 72.1 MHz | 9,948 | 2,670 | 32 |
| 8 lanes, no MATCH | 88.3 MHz | 9,879 (+50 RAM32M) | 5,505 | 32 |
| 8 lanes, MATCH with 2 units (`MATCH_LANES = 2`) | 83.6 MHz | 18,447 (+50 RAM32M) | 6,168 | 32 |
| 8 lanes, MATCH with 8 units | did not route: stopped after 52 minutes in the router's first pass, 63,127 overused wires | 41,446 (+50 RAM32M) | 5,615 | 32 |
| 16 lanes × 1,024 words, no MATCH | 70.8 MHz | 19,864 (+74 RAM32M) | 9,254 | 32 |

**No configuration meets 125 MHz in this flow.** The runs found real
structural paths, which are fixed:
- the descriptor decode, a 64-bit add then compares in one cycle;
- the combinational ready chain from dispatch back to the descriptor
  source;
- block-RAM ports driven through logic;
- 64-deep popcount and lowest-set-bit chains;
- cross-lane crossbars ending in logic;
- control registers with about 1,000 loads each.

The fixes:
- registered sums;
- a 2-entry circular skid buffer with registered ready, so taking a
  descriptor only moves a read pointer;
- a registered outstanding-operation counter for the barrier;
- registered queue-full flags;
- registered addresses, write ports and masks;
- balanced trees;
- crossbars that end in registers;
- multi-cycle range and MATCH set-up;
- per-lane copies of the step's control registers and per-unit copies of
  the MATCH pattern and mask. These carry `keep`; without it Yosys merges
  them back.

What remains is mostly routing between lanes that the placer spreads over
the chip:
- **8 lanes:** about 1.7 ns of logic and 9.6 ns of routing, from a lane's
  result word through the popcount tree. With MATCH it is 0.8 ns of logic
  and 11.1 ns of routing, from a unit's window register into its compare.
- **16 lanes:** 0.6 ns of logic and 13.6 ns of routing, on the BULK
  crossbar. Its lanes are far apart.

nextpnr-xilinx's placer is weaker than Vivado's, which also replicates
high-fanout drivers and pipelines placement-critical nets itself. So these
numbers are pessimistic, but by how much is unknown. If Vivado also misses
125 MHz:
- run the engine from its own slower clock (LitePCIe stays at 125 MHz);
- or add a pipeline stage after the popcount.

## Resources (estimate)

Yosys `synth_xilinx -abc9 -nowidelut` (the flow above), 128 KiB bit store,
engine and PCIe core only (no LitePCIe, no DDR3 controller):

| Lanes × words per lane | MATCH units | LUTs | of XC7A100T (63,400) | Flip-flops | RAMB36 |
|---|---|---|---|---|---|
| 8 × 2,048 (default) | none | 9,879 | 16% | 5,505 | 32 |
| 8 × 2,048 | 2 | 18,447 | 29% | 6,168 | 32 |
| 8 × 2,048 | 8 | 41,446 | 65% | 5,615 | 32 |
| 16 × 1,024 | none | 19,864 | 31% | 9,254 | 32 |

A MATCH unit checks 64 positions × 64 mask bits per cycle and costs about
4,000 LUTs. `MATCH_LANES` sets the number of units independently of
`LANES`, which must be a multiple of it. With fewer units, each group of
`LANES` words is matched in `LANES / MATCH_LANES` sub-steps. 8 units do not
fit in practice; **2 units are the recommended LiteFury setting**, and the
LiteX default when `--match` is given (`--match-lanes N` changes it).

16 lanes double COUNT/FIND/BULK throughput per cycle, at twice the LUTs and
a lower clock in this flow: 70.8 against 88.3 MHz. At these clocks that is
still about 1.6× the 8-lane throughput.

## Performance

Cycle counts are measured by `make perf`: the host program's `bench`
against the Verilated core at 8 × 2,048 with 2 MATCH units. The DMA
stand-in offers one descriptor and takes one result beat per cycle, with no
PCIe latency. The counts are therefore the engine's own throughput. Rates
are given at 125 MHz, the target; this design doesn't reach it in the
open-source flow (see Timing). At the 83.6 MHz measured there for this
configuration, they scale by 0.67.

| Descriptor | Cycles each | Work | At 125 MHz |
|---|---|---|---|
| single-bit GET (random) | 1.003 | 1 bit | 125 M descriptors/s |
| COUNT, 1 Mbit | 2,057 | 1,048,576 bits | 16.5 µs, 64 Gbit/s |
| FIND1, 1 Mbit, not found | 2,057 | 1,048,576 bits | 16.5 µs |
| BULK XOR (dry), 8,192 words | 2,057 | 524,288 bits of dst | 16.5 µs, 32 Gbit/s of dst |
| MATCH (2 units), 16-bit pattern, 1 M positions | 8,213 | 1,048,576 positions | 65.7 µs, 16 G positions/s |

With 8 units MATCH took 2,066 cycles (63 G positions/s at 125 MHz), but that
configuration doesn't fit (see Resources).

**Against the CPU.** `host/cpu_bench.c` does the same work on the host:
popcount loops, and a MATCH that compilers vectorize (checked against a
naive one). Measured on this repository's build machine (Intel Xeon VM,
2.8 GHz, 4 vCPUs, AVX-512, `-O3 -march=native`), 128 KiB store:

| Work (128 KiB store) | CPU, 1 thread | CPU, 4 threads (total) | Card at 125 MHz | Card at 83.6 MHz |
|---|---|---|---|---|
| COUNT, 1 Mbit | 10.5 µs (100 Gbit/s) | 210 Gbit/s | 64 Gbit/s | 43 Gbit/s |
| XOR + count, 2 × 64 KiB | 8.9 µs (59 Gbit/s of dst) | 217 Gbit/s | 32 Gbit/s | 21 Gbit/s |
| MATCH, 16-bit pattern | 2.0 G positions/s | 7.0 G positions/s | 16 G positions/s (2 units) | 10.7 G positions/s |
| MATCH, 64-bit pattern | 4.0 G positions/s | 8.9 G positions/s | 16 G positions/s (2 units) | 10.7 G positions/s |

**Verdict:**
- **COUNT and BULK:** the card is slower than one CPU core.
- **MATCH with 2 units:**
  - at 125 MHz, about 2× this machine's 4 threads and 4–8× one thread;
  - at the 83.6 MHz of the open-source estimate, about 1.2–1.5× the 4
    threads.

  It is the only operation where the card is expected to beat the CPU, and
  only by a small margin on a 4-core host. These are cycle counts times an
  assumed clock, not hardware measurements.

I haven't measured the NUC; run `host/cpu_bench` there to compare with its
real CPU.

## Generated-code note

LiteX's generated `liblitepcie/litepcie_dma.c` (at the LiteX revision used
here) checks `if (poll < 0)` instead of the return value of `poll()`, so poll
errors are ignored. The host program builds that file as shipped, without
`-Werror`.
