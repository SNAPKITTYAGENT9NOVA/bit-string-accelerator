//! Byte-level protocol of `fpga/rtl/fpga_top.sv`. Multi-byte fields are little-endian.

/// Opcodes accepted by the accelerator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Get = 0,
    Test = 1,
    Set = 2,
    Clear = 3,
    Toggle = 4,
}

impl Op {
    pub fn parse(s: &str) -> Option<Op> {
        match s.to_ascii_lowercase().as_str() {
            "get" => Some(Op::Get),
            "test" => Some(Op::Test),
            "set" => Some(Op::Set),
            "clear" => Some(Op::Clear),
            "toggle" => Some(Op::Toggle),
            _ => None,
        }
    }
}

pub const PING: u8 = b'P';
pub const PONG: u8 = b'B';
pub const WRITE: u8 = b'W';
pub const WRITE_ACK: u8 = b'K';
pub const READ: u8 = b'R';
pub const EXEC: u8 = b'X';
pub const UNKNOWN: u8 = b'?';
pub const STATUS_TAG: u8 = 0xA0;
pub const STATUS_TAG_MASK: u8 = 0xFC;

/// Number of 64-bit words in the FPGA RAM; byte addresses 0..WORDS*8 are in range.
pub const WORDS: usize = 256;

pub fn write_frame(index: u8, value: u64) -> Vec<u8> {
    let mut f = vec![WRITE, index];
    f.extend_from_slice(&value.to_le_bytes());
    f
}

pub fn read_frame(index: u8) -> Vec<u8> {
    vec![READ, index]
}

/// `opcode` is sent as given (3 bits), so undefined opcodes 5..=7 can be exercised.
pub fn exec_frame(opcode: u8, base: u64, offset: u64) -> Vec<u8> {
    let mut f = vec![EXEC, opcode & 0x07];
    f.extend_from_slice(&base.to_le_bytes());
    f.extend_from_slice(&offset.to_le_bytes());
    f
}

/// Result of one accelerator operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status {
    pub error: bool,
    /// Meaningful only when `error` is false.
    pub bit: bool,
}

/// Describe a reply byte that was not the one expected.
pub fn unexpected(what: &str, byte: u8) -> String {
    if byte == UNKNOWN {
        format!("{what}: the FPGA did not recognize the command (reply '?')")
    } else {
        format!("{what}: unexpected reply 0x{byte:02x}")
    }
}

pub fn parse_status(byte: u8) -> Result<Status, String> {
    if byte & STATUS_TAG_MASK != STATUS_TAG {
        return Err(format!("unexpected status byte 0x{byte:02x}"));
    }
    Ok(Status {
        error: byte & 0x02 != 0,
        bit: byte & 0x01 != 0,
    })
}

/// Host-side reference model of one operation on a RAM image, matching the RTL:
/// effective bit = (base << 3) + offset (mod 2^64), byte address = (bit >> 6) << 3,
/// out-of-range addresses and undefined opcodes report an error and do not write.
pub fn model_exec(ram: &mut [u64; WORDS], opcode: u8, base: u64, offset: u64) -> Status {
    let eff = (base << 3).wrapping_add(offset);
    let word = eff >> 6;
    let bit = (eff & 63) as u32;
    if word >= WORDS as u64 || opcode > 4 {
        return Status {
            error: true,
            bit: false,
        };
    }
    let w = &mut ram[word as usize];
    let old = (*w >> bit) & 1 == 1;
    let mask = 1u64 << bit;
    let new_bit = match opcode {
        2 => {
            *w |= mask;
            true
        }
        3 => {
            *w &= !mask;
            false
        }
        4 => {
            *w ^= mask;
            !old
        }
        _ => old,
    };
    Status {
        error: false,
        bit: new_bit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_little_endian() {
        assert_eq!(
            write_frame(3, 0x0102_0304_0506_0708),
            vec![b'W', 3, 8, 7, 6, 5, 4, 3, 2, 1]
        );
        assert_eq!(read_frame(255), vec![b'R', 255]);
        let x = exec_frame(Op::Toggle as u8, 0x11, 0x2233);
        assert_eq!(x.len(), 18);
        assert_eq!(&x[..2], &[b'X', 4]);
        assert_eq!(&x[2..10], &0x11u64.to_le_bytes());
        assert_eq!(&x[10..], &0x2233u64.to_le_bytes());
    }

    #[test]
    fn status_byte() {
        assert_eq!(
            parse_status(0xA0),
            Ok(Status {
                error: false,
                bit: false
            })
        );
        assert_eq!(
            parse_status(0xA1),
            Ok(Status {
                error: false,
                bit: true
            })
        );
        assert!(parse_status(0xA2).unwrap().error);
        assert!(parse_status(b'K').is_err());
        assert!(parse_status(0xB1).is_err());
    }

    #[test]
    fn model_matches_rtl_rules() {
        let mut ram = [0u64; WORDS];
        ram[0] = 0x8000_0000_0000_0001;
        assert_eq!(
            model_exec(&mut ram, 0, 0, 63),
            Status {
                error: false,
                bit: true
            }
        );
        assert_eq!(
            model_exec(&mut ram, 2, 8, 6),
            Status {
                error: false,
                bit: true
            }
        );
        assert_eq!(ram[1], 0x40);
        // (7 << 3) + 9 = bit 65 = word 1, bit 1: was 0, toggles to 1.
        assert_eq!(
            model_exec(&mut ram, 4, 7, 9),
            Status {
                error: false,
                bit: true
            }
        );
        assert_eq!(ram[1], 0x42);
        assert!(model_exec(&mut ram, 0, 2048, 0).error); // byte 2048 is past the RAM
        assert!(model_exec(&mut ram, 5, 0, 0).error); // undefined opcode
        assert!(model_exec(&mut ram, 0, u64::MAX, 0).error);
    }

    #[test]
    fn op_names() {
        assert_eq!(Op::parse("TOGGLE"), Some(Op::Toggle));
        assert_eq!(Op::parse("nope"), None);
    }
}
