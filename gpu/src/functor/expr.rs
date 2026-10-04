use super::{Add, GpuContext, GpuError, Negate, Result, UnaryOp};
use ocl::Buffer;

/// Expression tree of GPU operations, e.g. `Negate(Add(x, y))`.
/// Every node executes as an OpenCL kernel; nothing is computed on the host.
#[derive(Clone, Debug)]
pub enum Expr {
    Input(usize),
    Negate(Box<Expr>),
    Add(Box<Expr>, Box<Expr>),
}

enum Val<'a> {
    Borrowed(&'a Buffer<u8>),
    Owned(Buffer<u8>),
}

impl Val<'_> {
    fn buf(&self) -> &Buffer<u8> {
        match self {
            Val::Borrowed(b) => b,
            Val::Owned(b) => b,
        }
    }
}

impl Expr {
    pub fn input(i: usize) -> Expr {
        Expr::Input(i)
    }
    pub fn negate(e: Expr) -> Expr {
        Expr::Negate(Box::new(e))
    }
    pub fn add(a: Expr, b: Expr) -> Expr {
        Expr::Add(Box::new(a), Box::new(b))
    }

    /// Evaluate on the device over the first `count` elements of `inputs`.
    /// Inputs are never mutated; the result is a fresh buffer of `count` elements.
    pub fn eval(&self, ctx: &GpuContext, inputs: &[&Buffer<u8>], count: usize) -> Result<Buffer<u8>> {
        if count == 0 {
            return Err(GpuError::InvalidCount(0));
        }
        match self.eval_val(ctx, inputs, count)? {
            Val::Owned(b) => Ok(b),
            Val::Borrowed(src) => {
                let out = ctx.alloc(count)?;
                Identity.launch(ctx, src, &out, count)?;
                Ok(out)
            }
        }
    }

    fn eval_val<'a>(
        &self,
        ctx: &GpuContext,
        inputs: &[&'a Buffer<u8>],
        count: usize,
    ) -> Result<Val<'a>> {
        match self {
            Expr::Input(i) => inputs
                .get(*i)
                .map(|b| Val::Borrowed(*b))
                .ok_or(GpuError::MissingInput { index: *i, supplied: inputs.len() }),
            Expr::Negate(e) => {
                let v = e.eval_val(ctx, inputs, count)?;
                let out = ctx.alloc(count)?;
                Negate.launch(ctx, v.buf(), &out, count)?;
                Ok(Val::Owned(out))
            }
            Expr::Add(a, b) => {
                let va = a.eval_val(ctx, inputs, count)?;
                let vb = b.eval_val(ctx, inputs, count)?;
                let out = ctx.alloc(count)?;
                Add.launch(ctx, va.buf(), vb.buf(), &out, count)?;
                Ok(Val::Owned(out))
            }
        }
    }
}

/// Device-side copy, used only when an expression is a bare `Input`.
struct Identity;

impl UnaryOp for Identity {
    fn launch(&self, ctx: &GpuContext, input: &Buffer<u8>, output: &Buffer<u8>, count: usize) -> Result<()> {
        ctx.work_sizes(count, &[("input", input.len()), ("output", output.len())])?;
        input
            .cmd()
            .queue(ctx.proque().queue())
            .copy(output, Some(0), Some(count))
            .enq()?;
        Ok(())
    }
}
