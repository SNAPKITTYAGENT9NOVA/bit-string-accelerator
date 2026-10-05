use super::{GpuError, Result};

pub const CANONICAL_FALSE: u8 = 0x00;
pub const CANONICAL_TRUE: u8 = 0x01;

pub fn is_canonical(value: u8) -> bool {
    value == CANONICAL_FALSE || value == CANONICAL_TRUE
}

pub fn validate_buffer(buf: &[u8]) -> Result<()> {
    for (i, &byte) in buf.iter().enumerate() {
        if !is_canonical(byte) {
            return Err(GpuError::Ocl(ocl::Error::from(format!(
                "non-canonical boolean at index {}: expected 0x00 or 0x01, got 0x{:02x}",
                i, byte
            ))));
        }
    }
    Ok(())
}

pub fn bools_to_gpu(values: &[bool]) -> Vec<u8> {
    values
        .iter()
        .map(|&v| if v { CANONICAL_TRUE } else { CANONICAL_FALSE })
        .collect()
}

pub fn gpu_to_bools(values: &[u8]) -> Result<Vec<bool>> {
    validate_buffer(values)?;
    Ok(values.iter().map(|&v| v != CANONICAL_FALSE).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_canonical_exactly_zero_and_one() {
        for v in 0..=u8::MAX {
            assert_eq!(is_canonical(v), v <= 1, "value 0x{v:02x}");
        }
    }

    #[test]
    fn validate_buffer_reports_first_non_canonical() {
        assert!(validate_buffer(&[]).is_ok());
        assert!(validate_buffer(&[0, 1, 1, 0]).is_ok());
        for bad in 2..=u8::MAX {
            let err = validate_buffer(&[0, 1, bad, 7]).unwrap_err().to_string();
            assert!(err.contains("index 2"), "{err}");
            assert!(err.contains(&format!("0x{bad:02x}")), "{err}");
        }
    }

    #[test]
    fn bools_round_trip() {
        let values = [true, false, false, true, true];
        let bytes = bools_to_gpu(&values);
        assert_eq!(bytes, vec![1, 0, 0, 1, 1]);
        assert_eq!(gpu_to_bools(&bytes).unwrap(), values);
        assert!(gpu_to_bools(&[1, 2]).is_err());
    }
}
