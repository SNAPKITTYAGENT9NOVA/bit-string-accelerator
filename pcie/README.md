# PCIe accelerator (LiteFury)

The parallel version of the bit accelerator, attached to a host over PCIe.
`rtl/bit_accelerator.sv` is the golden functional reference, and the
parallel engine must produce identical results.

```
host RAM ──DMA reader──▶ descriptors ─▶ dispatch ─┬▶ lane 0 … lane N-1 ─┬▶ reorder buffer ─▶ results ──DMA writer──▶ host RAM
                         (128-bit)                 │ (word w → lane w mod N)│  (descriptor order)  (64-bit, 2 per beat)
                                                   └▶ range unit ──────────┘
                                                      (all lanes at once)
CSRs (BAR0): word access to the bit store, status, counters, geometry, format version
```

| Path | Contents |
|---|---|
| `rtl/bitacc_engine.sv` | N lanes, each owning one memory bank; range unit; reorder buffer; host word port |
| `rtl/bitacc_pcie_core.sv` | 128-bit descriptor/result streams, result packing, register interface |
| `tb/gold_ops.svh` | reference semantics of every operation, executed on the reference core |
| `tb/range_stim.svh` | random range-operation stimulus and coverage goals |
| `tb/tb_engine.sv` | engine vs the reference core |
| `tb/tb_pcie_core.sv` | PCIe core vs the reference core |
| `../formal/lane_map.mlw` | Why3 proof of the BULK lane-mapping arithmetic |
| `litex/bitacc_litefury.py` | LiteX SoC: LitePCIe Gen2 x4, one DMA channel, CSRs, DDR3 controller |
| `host/bitacc_pcie.c` | Linux host program (`info`, `selftest`, `bench`) on the generated liblitepcie |
| `host/sim/mock_litepcie.cpp` | liblitepcie stand-in backed by the Verilated core, for co-simulation |

## Operations

One 16-byte descriptor per operation (format version 2, readable from the
`version` CSR):

| Bits | Field |
|---|---|
| `[63:0]` | `a`: bit address (single-bit and bit-range operations), or destination word (BULK) |
| `[67:64]` | opcode |
| `[68]` | `dry`: BULK computes and counts without writing |
| `[71:69]` | `fn`: BULK function |
| `[103:72]` | `len`: range length in bits, or in words for BULK |
| `[127:104]` | `src`: source word (BULK) |

| Opcode | Operation | Result value | Result bit |
|---|---|---|---|
| 0 GET, 1 TEST | read bit `a` | 0 | the bit |
| 2 SET, 3 CLEAR, 4 TOGGLE | write bit `a` | 0 | the new bit |
| 8 COUNT | count set bits in `[a, a+len)` | the count | count ≠ 0 |
| 9 FIND1, 10 FIND0 | first set / clear bit in `[a, a+len)` | its index (0 if none) | found |
| 11 SETR, 12 CLEARR, 13 FLIPR | set / clear / invert every bit of `[a, a+len)` | set bits before the operation | value ≠ 0 |
| 14 BULK | `dst[k] = fn(dst[k], src[k])` for words `k < len`; fn 0 COPY, 1 AND, 2 OR, 3 XOR, 4 ANDN (`dst & ~src`) | set bits in the results | value ≠ 0 |
| 5–7, 15 | undefined | error | |

One 8-byte result per descriptor, in descriptor order:
`[7:0] = 0xA0 | error << 1 | bit` (the UART builds' status byte), `[63:8] = value`.

These are errors, with no write and a result of bit 0, value 0:
- A single-bit address outside the store.
- A bit range with `a + len > words × 64`, including 64-bit wrap.
- A BULK region outside the store.
- A BULK with partially overlapping regions. Identical regions are allowed.
- `fn > 4`.
- An undefined opcode.

`len = 0` is valid: the value is 0 and FIND finds nothing.

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
bit. Which range operations are errors is a specification choice, and it is
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
- About 8% range operations in every class: short (word-crossing),
  multi-step, empty, ending exactly at the end of the store, past the end,
  wrapping, and whole-store.
- BULK with disjoint, identical, overlapping and out-of-range regions,
  every function, and dry runs.
- FIND over regions a fill just emptied.
- Input gaps, and result backpressure with stalls long enough to fill the
  reorder buffer.

It compares every result (error, bit and value) and every final memory
word. It fails unless all of these actually occurred:
- every class above;
- out-of-order completion and a full reorder buffer;
- both barrier directions: a range operation waiting for busy lanes, and an
  operation waiting for a running range operation;
- FIND found and FIND not found.

Coverage is counted from what was executed, not from the generator's intent.

| Check | Result |
|---|---|
| Engine, 2×4, 4×16, 8×16, 8×512 lanes × words, seeds 1 and 7, 4,000 operations each (Icarus) | 0 mismatches. 8,069–24,432 checks per run; up to 1.45 M reference-core operations per run. |
| Engine under Verilator | 0 mismatches, all coverage goals met |
| PCIe core, 3,200 descriptors including 357 range operations (Icarus) | 9,893 checks, 0 failures |
| Host program against the Verilated core (`make cosim`) | 200,000 operations (5% range) and 50,000 (50% range): 0 mismatches |
| Host program at the LiteFury geometry, 8×2,048 (`make perf`) | 20,000 operations (20% range): 0 mismatches; 16,384 words checked |
| Injected faults, range unit | 22/22 detected. Examples: mask edges, rotation direction, BULK bound and last step, src/dst base, barrier in either direction, FIND lane order and first hit, overlap check, dry run, ANDN, fills of partial words, counting after instead of before, range end bound, missing dst read, stale value on an error result. Two further mutants were equivalent, with no observable effect, and were dropped: running an empty range through one step (every mask is zero, so nothing is written or counted), and returning `r_idx` for FIND not found (`r_idx` is already 0 then). |
| Injected faults, PCIe core | 9/9 detected (result order in a beat, value position, error/bit swap, opcode bit 3, len and src fields, fn/dry fields, beat size, counter step) |
| Injected faults, host co-simulation | FIND lane order, BULK rotation and fill count all detected (780–9,386 mismatches) |
| Lane mapping (`formal/lane_map.mlw`) | 58/58 goals proved by Z3 |
| Lint | `verilator -Wall` clean |

Problems found and fixed while building this:
- **The CI gate didn't gate.** `pcie/Makefile` ran testbenches as
  `vvp … | grep '^(checks|PASS)'`. A pipeline's status is grep's, and a
  failing run still prints its `checks=` line, so a failing simulation passed
  `make` (demonstrated with a mutant: `fails=6`, exit status 0). Every run now
  must exit 0 and print `PASS`.
- **The Verilator stimulus was not random.** Verilator 5.020's seeded
  `$random(seed)` roughly doubles the seed on each call, so values mod n
  followed a short pattern. Under Verilator, the previous engine testbench
  ran with a weak stimulus mix. The testbenches now use their own xorshift32
  generator.
- **The result packer stalled every third cycle.** It refused a result in
  the cycle it emitted a full beat, which capped single-bit throughput at
  0.666 descriptors per cycle. `make perf` measured this; the fix is in, and
  `make perf` now fails if throughput regresses.

The earlier testbench bugs (static stimulus variable, overcounting
out-of-order metric, watchdog reset by idle) stay fixed.

## Build

```sh
make lint                       # RTL lint
make -j8 sim sim-verilator      # equivalence runs (the 8x512 runs take ~6 minutes each)
make soc                        # LiteX sources + Linux driver (needs LiteX, no Vivado)
make cosim                      # host program against the Verilated core
make perf                       # cycle-level throughput at 8 lanes x 2048 words, with limits
make bitstream                  # needs Vivado (free edition covers the XC7A100T)
```

On the NUC, load the kernel driver from the generated
`build/litefury/driver/kernel`, then build and run the host program:

```sh
make -C host LITEPCIE=../build/litefury/driver
./host/bitacc_pcie info
./host/bitacc_pcie selftest 10000000 1 5     # operations, seed, % range operations
./host/bitacc_pcie bench count 100000        # also: get, find, xor
```

LiteX supports the LiteFury as the SQRL Acorn CLE-101, which litex-boards
documents as equivalent (`litex_boards/platforms/sqrl_acorn.py`). The same
bitstream works in the NUC's M.2 Key-M slot. It also works behind a USB4/
Thunderbolt enclosure that tunnels PCIe; nothing in the design depends on the
transport. I expect, but have not verified, that an ASM2464PD-based M.2
enclosure presents the card as a normal PCIe device in USB4/TB mode. It is
NVMe-only in USB 3 mode.

## Resources (estimate)

Yosys `synth_xilinx` for the engine and the PCIe core, with a 128 KiB bit
store in every case:

| Lanes × words per lane | LUTs | of XC7A100T | Flip-flops | RAMB36 |
|---|---|---|---|---|
| 8 × 2,048 (default) | 11,035 (+50 RAM32M) | 17% | 2,451 | 32 |
| 16 × 1,024 | 21,200 (+74 RAM32M) | 33% | 4,122 | 32 |
| 32 × 512 | 49,814 (+138 RAM32M) | 79% | 7,430 | 32 |

Before the range unit, the default geometry used about 3,330 LUTs. These
figures exclude LitePCIe and the DDR3 controller. Timing closure at
125 MHz has not been checked; that needs Vivado. 32 lanes is not a
realistic fit next to LitePCIe.

## Performance

Cycle counts are measured by `make perf`: the host program's `bench`
against the Verilated core at 8 × 2,048. The DMA stand-in offers one
descriptor and takes one result beat per cycle, with no PCIe latency. The
counts are therefore the engine's own throughput. Rates assume 125 MHz,
which is unverified.

| Descriptor | Cycles each | Bit store covered | At 125 MHz |
|---|---|---|---|
| single-bit GET (random) | 1.002 | 1 bit | 125 M descriptors/s, above the link's ~100–125 M/s |
| COUNT, 1 Mbit | 2,053 | 1,048,576 bits | 16.4 µs, 64 Gbit/s |
| FIND1, 1 Mbit, not found | 2,053 | 1,048,576 bits | 16.4 µs, 64 Gbit/s |
| BULK XOR (dry), 8,192 words | 2,053 | 524,288 bits of dst (and as many of src) | 16.4 µs, 32 Gbit/s of dst |

Bit ranges process N words per cycle; BULK processes N words per 2 cycles
(source read, then destination read and write). A 16-byte descriptor now
keeps the engine busy for up to 2,053 cycles, so PCIe is no longer the
limit for range operations.

**Against the CPU**, measured on one core of this repository's build
machine (Intel Xeon VM, 2.8 GHz, `cc -O2 -mpopcnt`), on the same 128 KiB:

| | CPU, one core | Card, 8 lanes at 125 MHz |
|---|---|---|
| COUNT, 128 KiB | 9.2 µs (113 Gbit/s) | 16.4 µs + PCIe round trip |
| XOR + count, 2 × 64 KiB | 5.3–6.6 µs (80–100 Gbit/s) | 16.4 µs + PCIe round trip |

**At 8 lanes the card does not beat one CPU core on range operations
either.** It is 1.8–3× slower, and a NUC has several cores. I have not
measured the NUC itself.

Range throughput scales linearly with lanes. At 16 lanes, COUNT would be
about 128 Gbit/s, roughly one core's speed, if 16 lanes close timing at
125 MHz. Neither the fit next to LitePCIe nor the timing is verified.

Beyond that, the BRAM-only bit store on an XC7A100T is the wall. The
DDR3 on the LiteFury (16-bit) is slower than its block RAM. A real speedup
needs either many more lanes than this FPGA holds (the custom PCIe board
or ASIC step of the roadmap), or operations where the CPU is weak.
Bit-parallel pattern matching is a candidate for the latter, but it is
neither implemented nor measured.

What this design does establish:
- operations whose work is independent of the link;
- lane-parallel range execution with ordered, verified results;
- a measured, regression-checked throughput.

## Generated-code note

LiteX's generated `liblitepcie/litepcie_dma.c` (at the LiteX revision used
here) checks `if (poll < 0)` instead of the return value of `poll()`, so poll
errors are ignored. The host program builds that file as shipped, without
`-Werror`.
