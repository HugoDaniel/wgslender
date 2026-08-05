//! A shader that is valid, asked to be judged strictly.
//!
//! The same file compiles without `strict = true`, which the integration suite
//! pins; that it stops compiling with it is the evidence that the key reaches
//! the library. See `embeds.rs` for why the path climbs.

const SHADER: &str = wgslender::include_wgsl!(
    "../../../../wgslender/tests/fixtures/warning.wgsl",
    strict = true
);

fn main() {
    let _ = SHADER;
}
