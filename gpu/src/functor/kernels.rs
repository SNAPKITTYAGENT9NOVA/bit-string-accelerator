//! Explicit OpenCL kernel signatures and metadata.
//!
//! Each kernel is formally declared with its name, parameter types, work item constraints,
//! and memory access patterns.

pub struct KernelSignature {
    pub name: &'static str,
    pub params: &'static [(&'static str, &'static str)],
    pub min_work_items: usize,
    pub safety_notes: &'static str,
}

pub const NEGATE_U8_SIGNATURE: KernelSignature = KernelSignature {
    name: "negate_u8",
    params: &[
        ("input", "__global const uchar*"),
        ("output", "__global uchar*"),
        ("element_count", "const ulong"),
    ],
    min_work_items: 1,
    safety_notes: "Kernel guards gid >= count. Input and output must not overlap. \
                   Canonical representation: input values must be 0x00 or 0x01. \
                   Output always produces 0x00 or 0x01.",
};

pub const ADD_U8_SIGNATURE: KernelSignature = KernelSignature {
    name: "add_u8",
    params: &[
        ("a", "__global const uchar*"),
        ("b", "__global const uchar*"),
        ("output", "__global uchar*"),
        ("count", "const uint"),
    ],
    min_work_items: 1,
    safety_notes: "Kernel guards gid >= count. Input buffers a, b must not overlap with output. \
                   Performs wrapping u8 addition: output[i] = (a[i] + b[i]) mod 256. \
                   On canonical boolean buffers (0x00, 0x01), produces values 0, 1, or 2.",
};

/// Registry of all OpenCL kernels in the functor system.
pub const KERNEL_REGISTRY: &[&KernelSignature] = &[&NEGATE_U8_SIGNATURE, &ADD_U8_SIGNATURE];

/// Validate kernel signature match at runtime.
/// Returns Ok if all registered kernels have valid signatures.
pub fn validate_registry() -> Result<(), String> {
    for kernel_sig in KERNEL_REGISTRY {
        if kernel_sig.name.is_empty() {
            return Err("kernel name cannot be empty".to_string());
        }
        if kernel_sig.params.is_empty() {
            return Err(format!("kernel '{}' must have parameters", kernel_sig.name));
        }
        for (param_name, param_type) in kernel_sig.params {
            if param_name.is_empty() || param_type.is_empty() {
                return Err(format!("kernel '{}': invalid parameter", kernel_sig.name));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_registry_is_valid() {
        validate_registry().expect("kernel registry validation failed");
    }

    #[test]
    fn negate_signature_is_correct() {
        assert_eq!(NEGATE_U8_SIGNATURE.name, "negate_u8");
        assert_eq!(NEGATE_U8_SIGNATURE.params.len(), 3);
        assert_eq!(
            NEGATE_U8_SIGNATURE.params[0],
            ("input", "__global const uchar*")
        );
        assert_eq!(NEGATE_U8_SIGNATURE.params[1], ("output", "__global uchar*"));
        assert_eq!(
            NEGATE_U8_SIGNATURE.params[2],
            ("element_count", "const ulong")
        );
    }

    #[test]
    fn add_signature_is_correct() {
        assert_eq!(ADD_U8_SIGNATURE.name, "add_u8");
        assert_eq!(ADD_U8_SIGNATURE.params.len(), 4);
        assert_eq!(ADD_U8_SIGNATURE.params[0], ("a", "__global const uchar*"));
        assert_eq!(ADD_U8_SIGNATURE.params[1], ("b", "__global const uchar*"));
        assert_eq!(ADD_U8_SIGNATURE.params[2], ("output", "__global uchar*"));
        assert_eq!(ADD_U8_SIGNATURE.params[3], ("count", "const uint"));
    }

    /// Every registered signature must describe the OpenCL source that is compiled:
    /// the kernel name and each `type name` parameter, in declaration order.
    #[test]
    fn registry_matches_kernel_sources() {
        let sources = [
            (&NEGATE_U8_SIGNATURE, super::super::negate::KERNEL_SRC),
            (&ADD_U8_SIGNATURE, super::super::add::KERNEL_SRC),
        ];
        assert_eq!(
            sources.len(),
            KERNEL_REGISTRY.len(),
            "a registered kernel has no source check"
        );
        for (sig, src) in sources {
            // Compare with all whitespace removed: "const uint count" == "constuintcount".
            let squashed: String = src.chars().filter(|c| !c.is_whitespace()).collect();
            let header = format!("__kernelvoid{}(", sig.name);
            let start = squashed
                .find(&header)
                .unwrap_or_else(|| panic!("kernel '{}' not found in its source", sig.name));
            let rest = &squashed[start + header.len()..];
            let declared: Vec<&str> = rest[..rest.find(')').expect("unterminated parameter list")]
                .split(',')
                .collect();
            let expected: Vec<String> = sig
                .params
                .iter()
                .map(|(name, ty)| format!("{ty}{name}").replace(' ', ""))
                .collect();
            assert_eq!(declared, expected, "kernel '{}' parameters", sig.name);
        }
    }

    #[test]
    fn all_kernels_have_min_work_items() {
        for kernel_sig in KERNEL_REGISTRY {
            assert!(
                kernel_sig.min_work_items >= 1,
                "kernel '{}' must allow at least 1 work item",
                kernel_sig.name
            );
        }
    }
}
