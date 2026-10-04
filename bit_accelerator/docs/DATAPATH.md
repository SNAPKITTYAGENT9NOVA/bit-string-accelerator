# Bit-Accelerator Datapath Architecture

## 1. High-Level Datapath Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                     BIT ACCELERATOR DATAPATH                         │
└─────────────────────────────────────────────────────────────────────┘

Stage 0: DECODE & OPERAND FETCH
┌──────────────┐
│   Opcode     │──────────► Opcode Decoder (6-to-12 decoder)
│   Operands   │──────────► Register File (3R1W)
│              │
└──────────────┘
     │
     ▼
Stage 1: ADDRESS GENERATION
┌──────────────────────────────────────────┐
│  Adder (Rs1 + Rs2)  ◄─── 64-bit Carry    │
│  eff_bit_address = base + offset         │
│                                          │
│  Output: 64-bit effective bit address    │
└──────────────────────────────────────────┘
     │
     ▼
Stage 2: WORD & BIT INDEX CALCULATION
┌──────────────────────────────────────┐
│  Divider / Shifter (÷64 & mod 64)    │
│  word_index = eff_addr >> 6          │  Combinational or pipelined
│  bit_index  = eff_addr & 0x3F        │
│                                      │
│  Output: (word_index[57:0], bit_idx) │
└──────────────────────────────────────┘
     │
     ▼
Stage 3: MEMORY ACCESS & TLB LOOKUP
┌──────────────────────────────────────────┐
│  TLB Lookup (word_index → phys_address)  │
│  L1 Cache Tag/Index Match                │
│  Memory Request to Load/Store Queue      │
│                                          │
│  Output: 64-bit word from L1/L2/Memory   │
└──────────────────────────────────────────┘
     │
     ▼
Stage 4: BIT EXTRACTION
┌──────────────────────────────────────┐
│  Barrel Shifter                      │
│  (word >> bit_index)                 │
│                                      │
│  AND Gate (extract LSB)              │
│  result = shifted_word & 1           │
│                                      │
│  Output: 1-bit result                │
└──────────────────────────────────────┘
     │
     ▼
Stage 5: WRITEBACK
┌──────────────────────────────────────┐
│  Register File Write                 │
│  result ──► Rd                       │
└──────────────────────────────────────┘
```

---

## 2. Component Specifications

### 2.1 Address Generator (Stage 1)

**Component**: 64-bit Ripple-Carry Adder or Kogge-Stone Parallel-Prefix Adder

**Inputs**:
- `base_address[63:0]` from Rs1 register
- `bit_offset[63:0]` from Rs2 register
- `carry_in` = 0

**Outputs**:
- `effective_bit_address[63:0]`

**Latency**: 1 cycle (Kogge-Stone) or 2 cycles (simpler adder)

**Control Signals**:
- `enable_add`: 1 if instruction requires address computation
- `select_operand`: 0 = Rs1+Rs2, 1 = Rs3+Rs4 (for multi-register ops)

---

### 2.2 Word and Bit Index Calculator (Stage 2)

**Component**: Fixed-Point Divider (÷ 64) and Modulo-64 Unit

**Inputs**:
- `effective_bit_address[63:0]` from Address Generator

**Outputs**:
- `word_index[57:0]` = `effective_bit_address >> 6`
- `bit_index[5:0]` = `effective_bit_address[5:0]`

**Hardware Implementation**:
```
word_index[i] = effective_bit_address[i+6], for i = 0 to 57
bit_index[i]  = effective_bit_address[i],   for i = 0 to 5
```
(This is purely combinational wiring - no logic!)

**Latency**: 0 cycles (combinational)

---

### 2.3 TLB & Cache Lookup (Stage 3)

**Component**: TLB (Translation Lookaside Buffer) + L1 Cache Controller

**Inputs**:
- `word_index[57:0]` (virtual word address, 6-bit aligned = 6 bits from effective address)
- Control: `is_load`, `is_store`

**Outputs**:
- `cache_hit` (1-bit flag)
- `data_word[63:0]` (from L1 cache on hit)
- `phys_address[40:0]` (for miss → L2/Memory)

**Behavior**:

**On Hit** (L1 cache, TLB translate):
- Return data directly from cache (fastest path)
- Latency: 1 cycle

**On Miss** (TLB or L1 cache miss):
- Initiate memory request to L2
- Stall pipeline until data returns
- Latency: variable (10+ cycles to L2, 50+ to main memory)

**Special Case: Page Boundary**:
- If `bit_address` and `(bit_address + 63)` span different pages:
  - Hardware may need two memory accesses
  - OR: Load both words and merge results (dual-load architecture)

---

### 2.4 Barrel Shifter (Stage 4)

**Component**: 64-bit Logarithmic Shifter

**Inputs**:
- `word[63:0]` from memory/cache
- `bit_index[5:0]` from Index Calculator
- `shift_direction` (0=right, 1=left, from decoder)
- `rotate_mode` (0=shift, 1=rotate)

**Implementation** (Rotating 64-bit barrel shifter):
```
Level 0: Shift by 32: word[i] ← (shift_by_32 ? word[(i+32)%64] : word[i])
Level 1: Shift by 16: word[i] ← (shift_by_16 ? word[(i+16)%64] : word[i])
Level 2: Shift by  8: word[i] ← (shift_by_8  ? word[(i+8)%64]  : word[i])
Level 3: Shift by  4: word[i] ← (shift_by_4  ? word[(i+4)%64]  : word[i])
Level 4: Shift by  2: word[i] ← (shift_by_2  ? word[(i+2)%64]  : word[i])
Level 5: Shift by  1: word[i] ← (shift_by_1  ? word[(i+1)%64]  : word[i])

bit_index[5:0] is decoded into 6 control signals: {shift_by_32, ..., shift_by_1}
```

**Outputs**:
- `shifted_word[63:0]`

**Latency**: 1 cycle (combinational through 6 levels of muxes)

---

### 2.5 Bit Extractor (Stage 4, after shifter)

**Component**: AND gate + optional sign-extension logic

**Inputs**:
- `shifted_word[63:0]` from Barrel Shifter
- `mask[63:0]` (computed from field width)
  - Single bit: `mask = 64'h0000_0000_0000_0001`
  - Multi-bit (width w): `mask = (1 << w) - 1`

**Outputs**:
- `extracted_field[63:0]` = `shifted_word & mask`

**For BITLOAD** (single-bit extract):
- Output: `result[63:0]` with `result[0] = extracted_field[0]`, `result[63:1] = 0`

**For BITFIELD** (multi-bit extract):
- Output: `result[63:0]` = extracted field, zero-extended

**Latency**: 1 cycle (combinational AND + logic)

---

### 2.6 Control Unit (Combinational + Sequential)

**Combinational Decoder**:
```
Opcode[5:0] → 12 control signals:
  - enable_addr_gen
  - enable_mem_load
  - enable_mem_store
  - enable_shift
  - enable_extract
  - enable_writeback
  - shift_direction (L/R)
  - rotate_mode
  - field_width[5:0]
  - is_signed_extend
```

**Sequential State Machine** (for cache misses, exceptions):
```
State 0: IDLE → await instruction
State 1: EXECUTE → run datapath
State 2: MEMORY_WAIT → stall on L1 miss
State 3: EXCEPTION → handle fault
State 4: WRITEBACK → commit result
```

---

### 2.7 Register File (3-Read, 1-Write Port)

**Capacity**: 32 × 64-bit registers

**Read Ports**:
- Port A: Rs1 (base address)
- Port B: Rs2 (offset/secondary operand)
- Port C: Rs3 (value to write for BITSTORE)

**Write Port**:
- Port W: Rd (destination register)

**Access Time**: 1 cycle (combinational read, synchronous write)

---

## 3. Data Flow for BITLOAD Instruction

**Instruction**: `BITLOAD R5, R10, R15`

```
Clock | Stage | Operation
------|-------|-------------------------------------------
  0   |   0   | Decode BITLOAD, fetch R10=0x1000, R15=0x42
      |       | 
  1   |   1   | Address generator: eff_addr = 0x1000 + 0x42 = 0x1042
      |       | 
  2   |   2   | Index calc (combinational): 
      |       |   word_idx = 0x1042 >> 6 = 0x41
      |       |   bit_idx = 0x1042 & 0x3F = 0x02
      |       |
  3   |   3   | TLB lookup: word_index → phys_addr = 0x41000
      |       | L1 cache hit: word = 0xABCD_EF01_2345_6789
      |       |
  4   |   4   | Shifter: shifted = word >> 2 = 0x2AF37_BC04_8D15_9E
      |       | Extractor: result = shifted & 1 = 0
      |       |
  5   |   5   | Writeback: R5 ← 0
```

---

## 4. Pipeline Depth Analysis

**Best Case** (L1 hit):
- Stage 0: Decode (1 cycle)
- Stage 1: Address gen (1 cycle)
- Stage 2: Index calc (0 cycles, combinational)
- Stage 3: Memory access (1 cycle hit)
- Stage 4: Extract (1 cycle)
- Stage 5: Writeback (committed)
- **Total: 4 cycles latency**

**Worst Case** (L2 miss, then main memory):
- Stages 0-3: same as above
- Stage 3: Memory miss, initiate L2 request (10+ cycles)
- Stage 4: Extract (1 cycle)
- **Total: 15+ cycles latency**

---

## 5. Throughput Analysis

**Instruction Issue Rate**: 1 instruction per cycle (assuming no structural hazards)

**Bottlenecks**:
- Memory bandwidth: If high % of instructions are BITLOAD/BITSTORE
- Cache behavior: Working set fit in L1 cache is critical
- Register contention: Low (3 reads, 1 write per cycle is feasible)

**Optimization**: Dual-issue for independent bit operations:
- Issue BITLOAD + BITCOUNT in same cycle (different functional units)

---

## 6. Critical Path (for clock frequency)

The critical path is the longest combinational delay in the pipeline:

```
TDC = T_mux(operand select) + T_adder(64-bit) + T_setup(register)
    ≈ 0.3ns + 1.2ns + 0.2ns = 1.7ns
    ≈ 588 MHz (f_clock ≤ 1/1.7ns)
```

For 1+ GHz target, require pipelined adder (Kogge-Stone):
```
T_KS_adder ≈ 0.8ns → allows ~1.2 GHz
```

---

## 7. Physical Implementation Details

### 7.1 Gate Counts (Estimates)

| Component | Gates |
|-----------|-------|
| 64-bit Adder (Kogge-Stone) | 1,500 |
| Barrel Shifter (6 levels) | 4,000 |
| TLB (16-32 entries) | 5,000 |
| L1 Cache Interface | 10,000 |
| Register File (32×64) | 20,000 |
| Control Decoder + FSM | 3,000 |
| Data Muxes, AND gates, misc | 5,000 |
| **Total estimate** | **~50k gates** |

### 7.2 Area Estimate

- Technology: 7nm FinFET
- Gate density: ~80M gates/mm²
- **Area ≈ 50k / 80M ≈ 0.6 mm²** (sub-mm² functional unit)

### 7.3 Power Estimate

- Dynamic power: ~2mW (1 GHz, 1.2V, 50k gates, 80% switching activity)
- Static power: ~0.5mW (leakage)
- **Total: ~2.5mW** (idle or active, instruction-dependent)

---

## 8. Memory System Integration

### 8.1 Memory Hierarchy

```
CPU Pipeline
    ↓
L1 I-Cache (32 KB)  ←── 1 cycle (instructions)
L1 D-Cache (32 KB)  ←── 1 cycle (data for BITLOAD)
    ↓ (miss)
L2 Cache (256 KB)   ←── 10 cycles
    ↓ (miss)
L3 Cache (8 MB)     ←── 30 cycles
    ↓ (miss)
Main Memory (DDR4)  ←── 50+ cycles
```

### 8.2 TLB Integration

```
Virtual Bit Address (64-bit)
    ↓
Extract word_index[57:0] = bit_address[63:6]
    ↓
TLB lookup (16-entry, 4-way associative)
    ├─► Hit: phys_word_addr = phys_base[40:0] | word_index[13:0]
    ├─► Miss: page walk (25+ cycles)
    ↓
L1 Cache tag lookup
```

### 8.3 Boundary Conditions

**Case 1**: Bit 0-63 fit in single 64-bit word
- Single memory access (normal path)

**Case 2**: Extract bits spanning two words (e.g., bits 60-65)
- Hardware loads both words
- Shifts, masks, combines
- Transparent to ISA

**Case 3**: Bits span two pages (e.g., word 0x1FFFF to 0x20000)
- May require two separate TLB lookups + memory accesses
- Hardware handles by stalling until both words available
- Or: Software constraint to avoid (less common)

---

## 9. Write-Path (BITSTORE)

```
BITSTORE Rs1, Rs2, Rs3

Stage 1: Address gen → eff_addr = Rs1 + Rs2
Stage 2: Index calc → word_idx, bit_idx
Stage 3: TLB lookup + load current word
Stage 4: Bit mask & merge:
         mask = 1 << bit_idx
         new_word = (old_word & ~mask) | ((Rs3 & 1) << bit_idx)
Stage 5: Store new_word back to memory (writeback cache)
```

**Read-Modify-Write**:
- Load old word: 3 cycles
- Compute new value: 1 cycle
- Store: pipelined (doesn't wait for commit)
- **Total latency: 4-5 cycles**

---

## 10. Register Transfer Language (RTL) Skeleton

```verilog
// Stage 1: Address Generation
reg [63:0] eff_addr;
always @(posedge clk)
  eff_addr <= rs1_data + rs2_data;

// Stage 2: Index Calculation (combinational)
wire [57:0] word_index = eff_addr[63:6];
wire [5:0] bit_index = eff_addr[5:0];

// Stage 3: Memory Access
wire [63:0] memory_word = l1_cache_read(word_index);

// Stage 4: Bit Extraction
wire [63:0] shifted = memory_word >> bit_index;
wire [63:0] extracted = shifted & 64'h1;

// Stage 5: Writeback
always @(posedge clk)
  rd_data <= extracted;
```

