# Bit Accelerator ISA

64-bit base address, 64-bit bit offset.

| Opcode | Operation |
|---|---|
| 000 | BIT_GET |
| 001 | BIT_TEST |
| 010 | BIT_SET |
| 011 | BIT_CLEAR |
| 100 | BIT_TOGGLE |
| 101-111 | undefined: completes with `error = 1`, no write |

Inputs: `rs_base`, `rs_offset` or an immediate offset. Output: one-bit architectural result plus condition/result-valid status.

Bit numbering is least-significant-bit first within each 64-bit word. Memory addresses are byte addresses. The effective bit address is `(base << 3) + offset` modulo 2^64. The containing word address is `(effective_bit_address >> 6) << 3` and bit index is `effective_bit_address mod 64`.
