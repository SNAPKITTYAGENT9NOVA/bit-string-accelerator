# Bit-String Hardware Accelerator ISA Specification

## 1. ISA Overview

**Architecture**: RISC-style bit-manipulation ISA  
**Operand Width**: 64-bit integer registers  
**Word Size**: 64 bits  
**Addressing**: Bit-addressed linear address space  

---

## 2. Register File

```
Registers: R0-R31 (32 × 64-bit GPRs)
Special Registers:
  - R0: Hard-wired zero
  - R31: Return value / implicit accumulator
```

---

## 3. Instruction Format

### 3.1 R-Type (Register-Register)
```
┌─────────┬─────┬─────┬─────┬────────────┐
│ Opcode  │ Rd  │ Rs1 │ Rs2 │ Reserved   │
│ 6 bits  │ 5   │ 5   │ 5   │ 13 bits    │
└─────────┴─────┴─────┴─────┴────────────┘
```

### 3.2 I-Type (Register-Immediate)
```
┌─────────┬─────┬─────┬──────────────┐
│ Opcode  │ Rd  │ Rs1 │  Immediate   │
│ 6 bits  │ 5   │ 5   │  18 bits     │
└─────────┴─────┴─────┴──────────────┘
```

### 3.3 L-Type (Load Immediate)
```
┌─────────┬─────┬──────────────────────┐
│ Opcode  │ Rd  │      Immediate       │
│ 6 bits  │ 5   │     53 bits (sign-ext) │
└─────────┴─────┴──────────────────────┘
```

---

## 4. Opcode Assignments

| Mnemonic       | Opcode | Type | Semantics |
|----------------|--------|------|-----------|
| BITLOAD        | 0x01   | R    | rd ← mem[rs1 + rs2 bit offset] & 1 |
| BITSTORE       | 0x02   | R    | mem[rs1 + rs2 bit offset] ← rs3 & 1 |
| BITFIELD       | 0x03   | R    | rd ← (mem[rs1 + rs2] >> rs3) & ((1 << rs4) - 1) |
| BITTEST        | 0x04   | R    | flag ← (mem[rs1 + rs2] >> bit_offset) & 1 |
| BITCOUNT       | 0x05   | R    | rd ← popcount(mem[rs1]) |
| BITSCANFWD     | 0x06   | R    | rd ← first_set_bit(rs1) |
| BITSCANREV     | 0x07   | R    | rd ← last_set_bit(rs1) |
| LOADIMM64      | 0x08   | L    | rd ← immediate (53-bit sign-extended) |
| BITEXTRACT     | 0x09   | R    | rd ← extract_field(rs1, rs2, rs3) |
| BITINSERT      | 0x0A   | R    | rd ← insert_field(rs1, rs2, rs3, rs4) |
| BITROTL        | 0x0B   | R    | rd ← rotate_left(rs1, rs2) |
| BITROTR        | 0x0C   | R    | rd ← rotate_right(rs1, rs2) |

---

## 5. Instruction Semantics

### 5.1 BITLOAD (Single-Bit Load)

**Encoding**: `BITLOAD Rd, Rs1, Rs2`

**Operation**:
```
effective_bit_address = Rs1 + Rs2
word_index = effective_bit_address / 64
bit_index = effective_bit_address mod 64
Rd ← (memory[word_index] >> bit_index) & 1
```

**Constraints**:
- `Rs1`: Bit base address (64-bit)
- `Rs2`: Bit offset (64-bit)
- `Rd`: Destination register (bit 0 set, bits [63:1] = 0)
- No privilege required
- May fault: page fault if effective address invalid

**Latency**: 3 cycles (address generation + memory access + extract)

---

### 5.2 BITSTORE (Single-Bit Write)

**Encoding**: `BITSTORE Rs1, Rs2, Rs3`

**Operation**:
```
effective_bit_address = Rs1 + Rs2
word_index = effective_bit_address / 64
bit_index = effective_bit_address mod 64
bit_value = Rs3 & 1
old_word = memory[word_index]
mask = 1 << bit_index
new_word = (old_word & ~mask) | (bit_value << bit_index)
memory[word_index] ← new_word
```

**Constraints**:
- `Rs1`: Bit base address
- `Rs2`: Bit offset
- `Rs3`: Bit value (only bit 0 is meaningful)
- No destination register
- Requires write permission on target memory
- May fault: segmentation fault, write-protect fault

**Latency**: 3 cycles (address generation + RMW cycle)

---

### 5.3 BITFIELD (Multi-Bit Extract)

**Encoding**: `BITFIELD Rd, Rs1, Rs2, Rs3, Rs4`

**Operation**:
```
effective_bit_address = Rs1 + Rs2
word_index = effective_bit_address / 64
bit_index = effective_bit_address mod 64
field_width = Rs3
bit_offset_in_word = Rs4

word = memory[word_index]
extracted = (word >> bit_offset_in_word) & ((1 << field_width) - 1)
Rd ← extracted
```

**Constraints**:
- `field_width` must be in range [1, 64]
- If `bit_offset + field_width > 64`, behavior is undefined (may trap)
- No cross-boundary extraction in this instruction (use software loop)

**Latency**: 3 cycles

---

### 5.4 BITTEST (Test and Branch)

**Encoding**: `BITTEST Rs1, Rs2`

**Operation**:
```
effective_bit_address = Rs1 + Rs2
word_index = effective_bit_address / 64
bit_index = effective_bit_address mod 64
condition_flag ← (memory[word_index] >> bit_index) & 1
```

**Latency**: 3 cycles

**Conditional Execution**: Sets zero flag (ZF) in status register:
- `ZF = 0` if bit is set
- `ZF = 1` if bit is clear

---

### 5.5 BITCOUNT (Population Count)

**Encoding**: `BITCOUNT Rd, Rs1`

**Operation**:
```
Rd ← popcount(Rs1)
```

**Latency**: 2 cycles (specialized hardware)

---

### 5.6 BITSCANFWD (Find First Set Bit)

**Encoding**: `BITSCANFWD Rd, Rs1`

**Operation**:
```
If Rs1 = 0:
  Rd ← 64 (or undefined, behavior determined by hardware)
Else:
  Rd ← position of rightmost set bit (0-indexed)
  Range: Rd ∈ [0, 63]
```

**Latency**: 2-3 cycles

---

### 5.7 BITSCANREV (Find Last Set Bit)

**Encoding**: `BITSCANREV Rd, Rs1`

**Operation**:
```
If Rs1 = 0:
  Rd ← 64 (or undefined)
Else:
  Rd ← position of leftmost set bit (0-indexed)
  Range: Rd ∈ [0, 63]
```

**Latency**: 2-3 cycles

---

### 5.8 LOADIMM64 (Load 53-Bit Immediate)

**Encoding**: `LOADIMM64 Rd, immediate`

**Operation**:
```
Rd ← sign_extend(immediate[52:0], 64)
```

**Latency**: 1 cycle

---

### 5.9 BITEXTRACT (Field Extraction with Width)

**Encoding**: `BITEXTRACT Rd, Rs1, Rs2, Rs3`

**Operation**:
```
value = Rs1
start_bit = Rs2
field_width = Rs3

extracted = (value >> start_bit) & ((1 << field_width) - 1)
Rd ← extracted
```

**Latency**: 1 cycle (register-only, no memory)

---

### 5.10 BITINSERT (Field Insertion)

**Encoding**: `BITINSERT Rd, Rs1, Rs2, Rs3, Rs4`

**Operation**:
```
dest_value = Rs1
source_value = Rs2
start_bit = Rs3
field_width = Rs4

mask = ((1 << field_width) - 1) << start_bit
shifted_source = (source_value & ((1 << field_width) - 1)) << start_bit
Rd ← (dest_value & ~mask) | shifted_source
```

**Latency**: 2 cycles

---

### 5.11 BITROTL (Rotate Left)

**Encoding**: `BITROTL Rd, Rs1, Rs2`

**Operation**:
```
value = Rs1
rotate_amount = Rs2 mod 64
Rd ← (value << rotate_amount) | (value >> (64 - rotate_amount))
```

**Latency**: 2 cycles

---

### 5.12 BITROTR (Rotate Right)

**Encoding**: `BITROTR Rd, Rs1, Rs2`

**Operation**:
```
value = Rs1
rotate_amount = Rs2 mod 64
Rd ← (value >> rotate_amount) | (value << (64 - rotate_amount))
```

**Latency**: 2 cycles

---

## 6. Memory Semantics

### 6.1 Byte Ordering (Little-Endian)

All operations assume little-endian byte ordering:
```
Memory layout (64-bit word at address 0x00):
Bit 0    at byte 0, bit 0
Bit 7    at byte 0, bit 7
Bit 8    at byte 1, bit 0
Bit 63   at byte 7, bit 7
```

### 6.2 Alignment Requirements

- No alignment requirement for bit addresses
- Memory accesses are naturally granular to 64-bit words
- Unaligned word access: hardware loads containing word, extracts bits

### 6.3 Virtual Memory Integration

- Bit addresses translate to physical addresses via TLB
- `word_address = bit_address >> 6` (divide by 64)
- `word_address` is then translated through MMU
- Page boundaries: if `bit_address` and `bit_address+63` span different pages, may require two memory accesses
- Hardware handles transparently for single-bit operations
- Multi-word operations may trap if boundary conditions not met

### 6.4 Cache Coherency

- Follows processor's existing cache coherency protocol
- BITSTORE is treated as a regular write for coherency purposes
- No special coherency instruction needed

---

## 7. Exception Behavior

| Exception | Opcode | Trigger | Action |
|-----------|--------|---------|--------|
| PAGE_FAULT | Any memory op | Address not in TLB | Interrupt handler, retry |
| PROTECTION_FAULT | BITSTORE | Page not writable | Interrupt handler |
| INVALID_ADDRESS | Any memory op | Address > max physical | Trap |
| UNDEFINED_FIELD_WIDTH | BITFIELD | width = 0 or width > 64 | Trap |

---

## 8. Status Register (Implicit)

```
Bit Name    Meaning
0   ZF      Zero Flag (set by BITTEST)
1   CF      Carry Flag (unused in this ISA)
2-63        Reserved
```

---

## 9. Privilege Levels

All bit-string instructions are **user-mode executable**. No privilege escalation.

Exception: Bit addresses pointing to kernel memory may trigger protection faults.

---

## 10. Formal Semantics (First-Order Logic)

### Correctness Property: Single-Bit Load

```
∀ base, offset ∈ ℕ :
  let eff_addr = base + offset
  let word_idx = eff_addr >> 6
  let bit_idx = eff_addr mod 64
  BITLOAD base offset = (mem[word_idx] >> bit_idx) & 1
```

### Correctness Property: Single-Bit Store

```
∀ base, offset, value ∈ ℕ :
  let eff_addr = base + offset
  let word_idx = eff_addr >> 6
  let bit_idx = eff_addr mod 64
  let mask = 1 << bit_idx
  
  after BITSTORE base offset value:
    mem[word_idx] = (mem[word_idx] & ~mask) | ((value & 1) << bit_idx)
    ∀ j ≠ word_idx : mem[j] unchanged
```

### Correctness Property: Field Extraction

```
∀ value, start, width ∈ ℕ, width ≤ 64 :
  BITEXTRACT value start width = (value >> start) & ((1 << width) - 1)
```

---

## 11. Implementation Constraints

- **Max memory size**: 2^64 bits (addressable)
- **Max single extraction**: 64 bits per instruction
- **Max rotation**: Full 64-bit rotation with any offset
- **Frequency**: Target 1+ GHz (1-3 cycle latency operations)
- **Power**: < 2mW per operation (estimated)
- **Area**: ~100-200k gates (estimates as sub-module)

---

## 12. Future Extensions (Out of Scope)

- SIMD bit-parallel operations
- GPU integration
- Vector bit strings
- Conditional bit operations
- Atomic bit operations (hardware locks)

