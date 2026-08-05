//! An array whose elements are padded.
//!
//! The same refusal as `module_padded_matrix.rs`, reached through the array
//! rule: `array<vec3f, 4>` is four twelve-byte elements sixteen bytes apart.
//! See `embeds.rs` for why the path climbs.

wgslender::wgsl_module!(pub padded, "../../../../wgslender/tests/fixtures/padded_array.wgsl");

// Nothing uses the module — see `module_padded_matrix.rs`.
fn main() {}
