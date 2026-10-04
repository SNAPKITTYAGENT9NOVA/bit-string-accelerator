use super::{GpuContext, GpuError, Result, UnaryOp};
use ocl::Buffer;
use std::fmt;

pub(super) const KERNEL_SRC: &str = r#"
__kernel void negate_u8(__global const uchar* input,
                        __global uchar* output,
                        const ulong element_count) {
    const ulong i = (ulong)get_global_id(0);
    if (i >= element_count) {
        return;
    }
    output[i] = input[i] ^ (uchar)1;
}
"#;

/// Error type for Negate validation and execution failures.
#[derive(Debug, Clone)]
pub enum NegateError {
    /// Non-canonical Boolean value found at the given index.
    InvalidBoolean { index: usize, value: u8 },
    /// OpenCL error during device operations.
    OpenCl(String),
}

impl fmt::Display for NegateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NegateError::InvalidBoolean { index, value } => {
                write!(
                    f,
                    "invalid boolean at index {}: expected 0x00 or 0x01, got 0x{:02x}",
                    index, value
                )
            }
            NegateError::OpenCl(msg) => write!(f, "OpenCL error: {}", msg),
        }
    }
}

impl std::error::Error for NegateError {}

impl From<ocl::Error> for NegateError {
    fn from(e: ocl::Error) -> Self {
        NegateError::OpenCl(e.to_string())
    }
}

/// Logical negation `¬x`: `output[i] = !input[i]`, executed on the OpenCL device.
#[derive(Clone, Copy, Debug, Default)]
pub struct Negate;

impl Negate {
    /// Reference semantics of the functor on a single Boolean.
    pub fn denote(x: bool) -> bool {
        !x
    }

    /// Validate that all elements in the input buffer are canonical (0x00 or 0x01).
    /// Returns the first invalid (index, value) pair found, or Ok(()) if all canonical.
    fn validate_input(input_data: &[u8]) -> std::result::Result<(), NegateError> {
        for (i, &byte) in input_data.iter().enumerate() {
            if byte != 0x00 && byte != 0x01 {
                return Err(NegateError::InvalidBoolean {
                    index: i,
                    value: byte,
                });
            }
        }
        Ok(())
    }
}

impl UnaryOp for Negate {
    fn launch(
        &self,
        ctx: &GpuContext,
        input: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()> {
        let (global, local) =
            ctx.work_sizes(count, &[("input", input.len()), ("output", output.len())])?;
        if count == 0 {
            return Ok(());
        }

        // Download and validate input data before kernel submission
        let input_data = ctx.download_raw(input)?;
        let input_slice = input_data.get(..count).ok_or(GpuError::BufferTooShort {
            which: "input",
            len: input_data.len(),
            count,
        })?;

        Self::validate_input(input_slice)
            .map_err(|e| GpuError::Ocl(ocl::Error::from(e.to_string())))?;

        let kernel = ctx
            .proque()
            .kernel_builder("negate_u8")
            .global_work_size(global)
            .local_work_size(local)
            .arg(input)
            .arg(output)
            .arg(count as u64)
            .build()?;
        // SAFETY: arguments match the kernel signature; the kernel guards gid < count and
        // count <= both buffer lengths was validated above.
        unsafe { kernel.enq()? };
        Ok(())
    }
}
