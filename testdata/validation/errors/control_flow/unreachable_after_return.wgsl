// @test: errors/control_flow/unreachable-after-return
// @expect-error E0503 "unreachable"
// Code after return is unreachable

fn foo() -> f32 {
    return 1.0;
    let x = 2.0;
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
