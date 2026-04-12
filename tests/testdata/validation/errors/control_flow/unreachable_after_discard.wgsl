// @test: errors/control_flow/unreachable-after-discard
// @expect-error E0503 "unreachable"
// Code after discard is unreachable

@fragment
fn main() -> @location(0) vec4f {
    discard;
    return vec4f(0.0);
}
