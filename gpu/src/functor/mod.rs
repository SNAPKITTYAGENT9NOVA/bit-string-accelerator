//! Composable element-wise GPU operations over a Boolean/u8 buffer representation.
//!
//! Representation: one `u8` per element; canonical Booleans are `0` (false) and `1` (true).
//! `Negate` accepts only canonical input (it returns an error on any other byte) and
//! writes canonical output. `Add` is wrapping `u8` addition, so its output is canonical
//! only when no position has both inputs true.

mod add;
mod agents;
mod canonical;
mod expr;
mod kernels;
mod negate;

pub use add::Add;
pub use agents::{ExecutionAgent, ValidationAgent, VerificationAgent, Workflow};
pub use canonical::{
    CANONICAL_FALSE, CANONICAL_TRUE, bools_to_gpu, gpu_to_bools, is_canonical, validate_buffer,
};
pub use expr::Expr;
pub use kernels::{ADD_U8_SIGNATURE, KERNEL_REGISTRY, NEGATE_U8_SIGNATURE, validate_registry};
pub use negate::Negate;

use ocl::{Buffer, ProQue};
use std::fmt;

const DEFAULT_LOCAL_SIZE: usize = 64;

static INIT_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Debug)]
pub enum GpuError {
    Ocl(ocl::Error),
    /// Element count cannot be represented as the kernel's `uint` argument.
    InvalidCount(usize),
    /// A buffer is shorter than the requested element count.
    BufferTooShort {
        which: &'static str,
        len: usize,
        count: usize,
    },
    /// `Expr::Input(index)` refers to an input that was not supplied.
    MissingInput {
        index: usize,
        supplied: usize,
    },
    /// A zero-length device buffer was requested (OpenCL cannot allocate one).
    EmptyBuffer,
    /// A zero local work-group size was requested.
    InvalidLocalSize,
}

impl fmt::Display for GpuError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GpuError::Ocl(e) => write!(f, "OpenCL error: {e}"),
            GpuError::InvalidCount(n) => write!(f, "invalid element count {n} (must fit in u32)"),
            GpuError::BufferTooShort { which, len, count } => {
                write!(f, "{which} buffer has {len} elements but count is {count}")
            }
            GpuError::MissingInput { index, supplied } => {
                write!(f, "expression input {index} missing ({supplied} supplied)")
            }
            GpuError::EmptyBuffer => write!(f, "zero-length device buffers cannot be allocated"),
            GpuError::InvalidLocalSize => write!(f, "local work-group size must be non-zero"),
        }
    }
}

impl std::error::Error for GpuError {}

impl From<ocl::Error> for GpuError {
    fn from(e: ocl::Error) -> Self {
        GpuError::Ocl(e)
    }
}

pub type Result<T> = std::result::Result<T, GpuError>;

/// OpenCL context, queue and compiled program for all functor kernels.
pub struct GpuContext {
    proque: ProQue,
    local_size: usize,
}

impl GpuContext {
    /// Create a context on the default OpenCL device and compile all functor kernels.
    pub fn new() -> Result<Self> {
        Self::with_source(&Self::kernel_source())
    }

    /// Like [`GpuContext::new`] but with a requested work-group size (clamped to the device limit).
    pub fn with_local_size(local_size: usize) -> Result<Self> {
        let mut ctx = Self::new()?;
        ctx.set_local_size(local_size)?;
        Ok(ctx)
    }

    /// Build a context from arbitrary OpenCL source (compile errors are returned, not swallowed).
    pub fn with_source(src: &str) -> Result<Self> {
        // Validate kernel registry before creating context.
        validate_registry().map_err(|e| GpuError::Ocl(ocl::Error::from(e)))?;

        // Observed with pocl: concurrent first-time platform/device discovery from several
        // threads makes clGetDeviceIDs fail intermittently, so creation is serialised.
        let _guard = INIT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let proque = ProQue::builder().src(src.to_string()).build()?;
        let max = proque.device().max_wg_size()?;
        Ok(GpuContext {
            proque,
            local_size: DEFAULT_LOCAL_SIZE.min(max),
        })
    }

    pub fn set_local_size(&mut self, local_size: usize) -> Result<()> {
        if local_size == 0 {
            return Err(GpuError::InvalidLocalSize);
        }
        let max = self.proque.device().max_wg_size()?;
        self.local_size = local_size.min(max);
        Ok(())
    }

    pub fn local_size(&self) -> usize {
        self.local_size
    }

    pub fn device_name(&self) -> Result<String> {
        Ok(self.proque.device().name()?)
    }

    /// All functor kernels in one program.
    pub fn kernel_source() -> String {
        format!("{}\n{}", negate::KERNEL_SRC, add::KERNEL_SRC)
    }

    /// Allocate a zero-initialised device buffer of `len` bytes (len must be > 0).
    pub fn alloc(&self, len: usize) -> Result<Buffer<u8>> {
        self.alloc_filled(len, 0)
    }

    /// Allocate a device buffer filled with `val` (used to detect stale/out-of-bounds writes).
    pub fn alloc_filled(&self, len: usize, val: u8) -> Result<Buffer<u8>> {
        if len == 0 {
            return Err(GpuError::EmptyBuffer);
        }
        Ok(Buffer::<u8>::builder()
            .queue(self.proque.queue().clone())
            .len(len)
            .fill_val(val)
            .build()?)
    }

    /// Upload raw bytes to a new device buffer.
    pub fn upload_raw(&self, data: &[u8]) -> Result<Buffer<u8>> {
        if data.is_empty() {
            return Err(GpuError::EmptyBuffer);
        }
        Ok(Buffer::<u8>::builder()
            .queue(self.proque.queue().clone())
            .len(data.len())
            .copy_host_slice(data)
            .build()?)
    }

    pub fn upload_bools(&self, data: &[bool]) -> Result<Buffer<u8>> {
        let raw: Vec<u8> = data.iter().map(|&b| b as u8).collect();
        self.upload_raw(&raw)
    }

    pub fn download_raw(&self, buf: &Buffer<u8>) -> Result<Vec<u8>> {
        let mut out = vec![0u8; buf.len()];
        buf.cmd().queue(self.proque.queue()).read(&mut out).enq()?;
        Ok(out)
    }

    pub fn download_bools(&self, buf: &Buffer<u8>, count: usize) -> Result<Vec<bool>> {
        let raw = self.download_raw(buf)?;
        let slice = raw.get(..count).ok_or(GpuError::BufferTooShort {
            which: "download target",
            len: raw.len(),
            count,
        })?;
        validate_buffer(slice)?;
        Ok(slice.iter().map(|&b| b != 0).collect())
    }

    pub(crate) fn proque(&self) -> &ProQue {
        &self.proque
    }

    /// Validate `count` against the buffers and return `(global, local)` work sizes.
    /// Global size is rounded up to a multiple of local size, so kernels MUST guard `gid < count`.
    pub(crate) fn work_sizes(
        &self,
        count: usize,
        bufs: &[(&'static str, usize)],
    ) -> Result<(usize, usize)> {
        if count > u32::MAX as usize {
            return Err(GpuError::InvalidCount(count));
        }
        for &(which, len) in bufs {
            if len < count {
                return Err(GpuError::BufferTooShort { which, len, count });
            }
        }
        let local = self.local_size;
        Ok((count.div_ceil(local) * local, local))
    }
}

/// A unary device operation `F(A) -> F(A)` that is composable.
pub trait UnaryOp {
    /// Enqueue `output[i] = op(input[i])` for `i < count`. Elements at `i >= count` are untouched.
    /// `count == 0` is a no-op.
    fn launch(
        &self,
        ctx: &GpuContext,
        input: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()>;

    /// Sequential composition: `self.then(g)` computes `g(self(x))`.
    fn then<G: UnaryOp>(self, g: G) -> Compose<Self, G>
    where
        Self: Sized,
    {
        Compose {
            first: self,
            second: g,
        }
    }

    /// Convenience: run on host bools, executing on the device, returning a fresh Vec.
    fn run_bools(&self, ctx: &GpuContext, input: &[bool]) -> Result<Vec<bool>> {
        if input.is_empty() {
            return Ok(Vec::new());
        }
        let inp = ctx.upload_bools(input)?;
        let out = ctx.alloc(input.len())?;
        self.launch(ctx, &inp, &out, input.len())?;
        ctx.download_bools(&out, input.len())
    }
}

/// `Compose { first: F, second: G }` computes `G(F(x))` through a device temporary.
pub struct Compose<F, G> {
    first: F,
    second: G,
}

impl<F: UnaryOp, G: UnaryOp> UnaryOp for Compose<F, G> {
    fn launch(
        &self,
        ctx: &GpuContext,
        input: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()> {
        if count == 0 {
            return Ok(());
        }
        let tmp = ctx.alloc(count)?;
        self.first.launch(ctx, input, &tmp, count)?;
        self.second.launch(ctx, &tmp, output, count)
    }
}
