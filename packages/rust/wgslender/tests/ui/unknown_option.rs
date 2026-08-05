//! An option key the macro does not have.
//!
//! Naming the key is half the message; listing the ones that do exist is the
//! half that saves a trip to the documentation.
//!
//! The shader is a real one — see `embeds.rs` for why the path climbs — so that
//! the only thing wrong here is the key. A case that also pointed at a missing
//! file would keep passing if the option check were ever lost.

const SHADER: &str = wgslender::include_wgsl!(
    "../../../../wgslender/tests/fixtures/demo.wgsl",
    minify_idents = true
);

fn main() {
    let _ = SHADER;
}
