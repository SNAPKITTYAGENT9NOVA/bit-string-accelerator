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
    values.iter().map(|&v| if v { CANONICAL_TRUE } else { CANONICAL_FALSE }).collect()
}

pub fn gpu_to_bools(values: &[u8]) -> Result<Vec<bool>> {
    validate_buffer(values)?;
    Ok(values.iter().map(|&v| v != CANONICAL_FALSE).collect())
}
