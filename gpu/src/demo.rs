// Functor-based GPU architecture demonstration
// This shows the composable kernel design without requiring actual GPU hardware

trait Kernel: Sized {
    fn name() -> &'static str;
    fn local_size() -> usize;
    fn compute(&self, gid: usize, lid: usize) -> f32;
}

struct LocalIdKernel;

impl Kernel for LocalIdKernel {
    fn name() -> &'static str { "local_id" }
    fn local_size() -> usize { 4 }

    fn compute(&self, _gid: usize, lid: usize) -> f32 {
        lid as f32
    }
}

struct GlobalIdKernel;

impl Kernel for GlobalIdKernel {
    fn name() -> &'static str { "global_id" }
    fn local_size() -> usize { 4 }

    fn compute(&self, gid: usize, _lid: usize) -> f32 {
        gid as f32
    }
}

fn execute<K: Kernel>(kernel: K, work_size: usize) -> Vec<f32> {
    let local_size = K::local_size();
    (0..work_size)
        .map(|gid| {
            let local_id = gid % local_size;
            kernel.compute(gid, local_id)
        })
        .collect()
}

fn format_output(data: &[f32]) -> String {
    data.iter()
        .enumerate()
        .fold(String::new(), |acc, (i, &val)| {
            if i > 0 && i % 16 == 0 {
                format!("{}\n{:>3} ", acc, val as i32)
            } else {
                format!("{}{:>3} ", acc, val as i32)
            }
        })
}

fn main() {
    println!("=== Functor-Based GPU Kernel Architecture Demo ===\n");

    println!("Kernel: {} (local_size={})", LocalIdKernel::name(), LocalIdKernel::local_size());
    let result1 = execute(LocalIdKernel, 128);
    println!("Output: {}\n", format_output(&result1));

    println!("Kernel: {} (local_size={})", GlobalIdKernel::name(), GlobalIdKernel::local_size());
    let result2 = execute(GlobalIdKernel, 128);
    println!("Output: {}\n", format_output(&result2));

    println!("=== Architecture Proof ===");
    println!("✓ Kernel trait abstracts GPU operations");
    println!("✓ execute<K>() is a higher-order function parametrized on Kernel");
    println!("✓ Immutable data flow: kernel.compute() → Vec<f32>");
    println!("✓ Type-safe kernel composition via trait bounds");
}
