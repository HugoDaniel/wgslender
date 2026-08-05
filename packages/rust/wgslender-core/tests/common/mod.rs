//! Fixtures shared by the integration tests.
//!
//! Every test binary compiles this module separately and uses a subset of it,
//! so unused items here are expected rather than dead.
#![allow(dead_code)]

/// Four binding kinds, a struct, a helper function and one compute entry point.
pub(crate) const DEMO: &str = include_str!("../fixtures/demo.wgsl");

/// Two entry points that carry no workgroup size: one vertex, one fragment.
pub(crate) const RENDER: &str = include_str!("../fixtures/render.wgsl");

/// Type-checks against nothing: `undeclared_variable` is never declared.
pub(crate) const INVALID: &str = include_str!("../fixtures/invalid.wgsl");

/// Valid, but trips two warning-severity diagnostics.
pub(crate) const WARNING: &str = include_str!("../fixtures/warning.wgsl");

/// Not WGSL at all — the parser bails on it.
pub(crate) const UNPARSEABLE: &str = "fn main( { let ; }";

/// Valid and warning-free, but declares a helper nothing ever calls, so
/// `no-unused-vars` has something to find.
pub(crate) const UNUSED: &str = "\
@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

fn unused_helper(x: f32) -> f32 {
    return x * 2.0;
}

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
";

/// [`UNUSED`] with a file-level directive that switches `no-unused-vars` off.
pub(crate) const UNUSED_WITH_DIRECTIVE: &str = "\
// wgslender-disable no-unused-vars

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

fn unused_helper(x: f32) -> f32 {
    return x * 2.0;
}

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
";

/// Clean, but carries a directive for a rule that never fires — exactly what
/// `report_unused_disable_directives` exists to surface.
pub(crate) const DEAD_DIRECTIVE: &str = "\
// wgslender-disable no-self-assign

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
";
