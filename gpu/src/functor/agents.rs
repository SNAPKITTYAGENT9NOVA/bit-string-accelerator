use super::{GpuContext, GpuError, Result, UnaryOp};
use ocl::Buffer;

pub struct ValidationAgent;

impl ValidationAgent {
    pub fn validate_input(count: usize) -> Result<()> {
        if count == 0 {
            return Err(GpuError::EmptyBuffer);
        }
        if count > u32::MAX as usize {
            return Err(GpuError::InvalidCount(count));
        }
        Ok(())
    }

    pub fn validate_buffers(bufs: &[(&'static str, usize)], count: usize) -> Result<()> {
        for &(which, len) in bufs {
            if len < count {
                return Err(GpuError::BufferTooShort { which, len, count });
            }
        }
        Ok(())
    }

    pub fn allocate(ctx: &GpuContext, count: usize) -> Result<Buffer<u8>> {
        Self::validate_input(count)?;
        ctx.alloc(count)
    }
}

pub struct ExecutionAgent;

impl ExecutionAgent {
    pub fn execute<Op: UnaryOp>(
        ctx: &GpuContext,
        op: &Op,
        input: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()> {
        ValidationAgent::validate_input(count)?;
        ValidationAgent::validate_buffers(
            &[("input", input.len()), ("output", output.len())],
            count,
        )?;
        op.launch(ctx, input, output, count)
    }

    pub fn execute_composed<F: UnaryOp, G: UnaryOp>(
        ctx: &GpuContext,
        f: &F,
        g: &G,
        input: &Buffer<u8>,
        output: &Buffer<u8>,
        count: usize,
    ) -> Result<()> {
        ValidationAgent::validate_input(count)?;
        ValidationAgent::validate_buffers(
            &[("input", input.len()), ("output", output.len())],
            count,
        )?;
        let tmp = ctx.alloc(count)?;
        f.launch(ctx, input, &tmp, count)?;
        g.launch(ctx, &tmp, output, count)
    }
}

pub struct VerificationAgent;

impl VerificationAgent {
    pub fn download(ctx: &GpuContext, buf: &Buffer<u8>) -> Result<Vec<u8>> {
        ctx.download_raw(buf)
    }

    pub fn download_bools(ctx: &GpuContext, buf: &Buffer<u8>, count: usize) -> Result<Vec<bool>> {
        ctx.download_bools(buf, count)
    }

    pub fn verify_equal(actual: &[u8], expected: &[u8]) -> Result<()> {
        if actual != expected {
            return Err(GpuError::Ocl(ocl::Error::from(
                "verification failed: output mismatch",
            )));
        }
        Ok(())
    }

    pub fn verify_bools_equal(actual: &[bool], expected: &[bool]) -> Result<()> {
        if actual != expected {
            return Err(GpuError::Ocl(ocl::Error::from(
                "verification failed: boolean output mismatch",
            )));
        }
        Ok(())
    }
}

pub struct Workflow {
    ctx: GpuContext,
}

impl Workflow {
    pub fn new() -> Result<Self> {
        let ctx = GpuContext::new()?;
        Ok(Workflow { ctx })
    }

    pub fn run_unary<Op: UnaryOp>(
        &self,
        op: &Op,
        input: &[u8],
    ) -> Result<Vec<u8>> {
        let count = input.len();
        ValidationAgent::validate_input(count)?;

        let inp_buf = self.ctx.upload_raw(input)?;
        let out_buf = ValidationAgent::allocate(&self.ctx, count)?;

        ExecutionAgent::execute(&self.ctx, op, &inp_buf, &out_buf, count)?;

        VerificationAgent::download(&self.ctx, &out_buf)
    }

    pub fn run_unary_bools<Op: UnaryOp>(
        &self,
        op: &Op,
        input: &[bool],
    ) -> Result<Vec<bool>> {
        let count = input.len();
        ValidationAgent::validate_input(count)?;

        let inp_buf = self.ctx.upload_bools(input)?;
        let out_buf = ValidationAgent::allocate(&self.ctx, count)?;

        ExecutionAgent::execute(&self.ctx, op, &inp_buf, &out_buf, count)?;

        VerificationAgent::download_bools(&self.ctx, &out_buf, count)
    }

    pub fn run_composed<F: UnaryOp, G: UnaryOp>(
        &self,
        f: &F,
        g: &G,
        input: &[u8],
    ) -> Result<Vec<u8>> {
        let count = input.len();
        ValidationAgent::validate_input(count)?;

        let inp_buf = self.ctx.upload_raw(input)?;
        let out_buf = ValidationAgent::allocate(&self.ctx, count)?;

        ExecutionAgent::execute_composed(&self.ctx, f, g, &inp_buf, &out_buf, count)?;

        VerificationAgent::download(&self.ctx, &out_buf)
    }

    pub fn run_composed_bools<F: UnaryOp, G: UnaryOp>(
        &self,
        f: &F,
        g: &G,
        input: &[bool],
    ) -> Result<Vec<bool>> {
        let count = input.len();
        ValidationAgent::validate_input(count)?;

        let inp_buf = self.ctx.upload_bools(input)?;
        let out_buf = ValidationAgent::allocate(&self.ctx, count)?;

        ExecutionAgent::execute_composed(&self.ctx, f, g, &inp_buf, &out_buf, count)?;

        VerificationAgent::download_bools(&self.ctx, &out_buf, count)
    }

    pub fn device_name(&self) -> Result<String> {
        self.ctx.device_name()
    }
}
