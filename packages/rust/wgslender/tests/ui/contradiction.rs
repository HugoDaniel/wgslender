//! An invocation that argues with itself.
//!
//! `keep_names` asks the minifier to leave a name alone; `minify = false` means
//! there is no minifier to ask. Applying half of that quietly would leave the
//! author believing something is being kept. See `embeds.rs` for why the path
//! climbs.

const SHADER: &str = wgslender::include_wgsl!(
    "../../../../wgslender/tests/fixtures/demo.wgsl",
    minify = false,
    keep_names = ["luminance"]
);

fn main() {
    let _ = SHADER;
}
