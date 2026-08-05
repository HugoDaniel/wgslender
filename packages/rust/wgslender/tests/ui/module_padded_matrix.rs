//! A matrix whose columns are padded.
//!
//! `mat3x3f` is three twelve-byte columns sixteen bytes apart. `[[f32; 3]; 3]`
//! would be forty-eight tightly packed bytes, and a generated struct that
//! disagreed with the GPU by four bytes per column is exactly the bug this
//! macro exists to make impossible — so it refuses, by name. See `embeds.rs`
//! for why the path climbs.

wgslender::wgsl_module!(pub padded, "../../../../wgslender/tests/fixtures/padded_matrix.wgsl");

// Nothing uses the module: a use of it would fail to resolve as well, and that
// second error is noise on top of the message this case is about.
fn main() {}
