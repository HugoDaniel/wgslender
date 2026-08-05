//! `bytemuck` asked of a macro that generates no structs.
//!
//! The key names derives to put on generated types; `include_wgsl!` generates a
//! string literal. Accepting it there and doing nothing would leave the author
//! believing their shader struct is `Pod`. See `embeds.rs` for why the path
//! climbs.

const SHADER: &str = wgslender::include_wgsl!(
    "../../../../wgslender/tests/fixtures/demo.wgsl",
    bytemuck = true
);

fn main() {
    let _ = SHADER;
}
