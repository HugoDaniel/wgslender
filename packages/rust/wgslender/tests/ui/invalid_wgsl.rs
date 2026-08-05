//! A shader that parses but does not type-check.
//!
//! The library's own diagnostic — position, code and text — has to survive the
//! trip into a Rust compile error, or the macro has turned a precise complaint
//! into "the macro failed". See `embeds.rs` for why the path climbs.

const SHADER: &str = wgslender::include_wgsl!("../../../../wgslender/tests/fixtures/invalid.wgsl");

fn main() {
    let _ = SHADER;
}
