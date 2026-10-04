use super::{GpuContext, Result};
use ocl::Buffer;

pub(super) const KERNEL_SRC: &str = r#"
__kernel void add_u8(__global const uchar* a,
                     __global const uchar* b,
                     __global uchar* output,
                     const uint count) {
    size_t i = get_global_id(0);
    if (i >= count) {
        return;
    }
    output[i] = (uchar)(a[i] + b[i]);
}
"#;

/// Element-wise wrapping `u8` addition: `output[i] = a[i] + b[i]`.
/// On Booleans this is a counting sum (0, 1 or 2), so `Negate(Add(x, y))` is NOR.
#[derive(Clone, Copy, Debug, Default)]
pub struct Add;

impl Add {
    pub fn launch(
        &self,
        ctx: &GpuContext,
        a: &Buffer<u8>,
        b: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()> {
        let (global, local) = ctx.work_sizes(
            count,
            &[("a", a.len()), ("b", b.len()), ("output", output.len())],
        )?;
        if count == 0 {
            return Ok(());
        }
        let kernel = ctx
            .proque()
            .kernel_builder("add_u8")
            .global_work_size(global)
            .local_work_size(local)
            .arg(a)
            .arg(b)
            .arg(output)
            .arg(count as u32)
            .build()?;
        // SAFETY: see Negate::launch.
        unsafe { kernel.enq()? };
        Ok(())
    }
}
