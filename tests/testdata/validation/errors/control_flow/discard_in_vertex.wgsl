// @test: errors/control-flow/discard-in-vertex
// @expect-error E0502 "discard"
// Discard statement not allowed in vertex shader

@vertex
fn main() -> @builtin(position) vec4<f32> {
    discard;  // Error: discard not allowed in vertex shader
    return vec4<f32>(0.0);
}
