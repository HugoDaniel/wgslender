// @test: errors/control_flow/unreachable-after-return
// @expect-valid
// Code after `return` is statically unreachable, which is *valid* WGSL — it is
// type-checked but never runs (Tint accepts it). wgslender flags it with a
// non-fatal W0103 warning (batch 12 downgraded this from a hard E0503 error);
// the W0103 advisory itself is asserted by the inline tests in validation_test.zig.

fn foo() -> f32 {
    return 1.0;
    let x = 2.0;
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
