// @test: errors/control-flow/discard-outside-fragment
// @expect-error E0502 "discard"
// Discard statement must be in fragment shader

@compute @workgroup_size(1)
fn main() {
    discard;  // Error: discard not allowed in compute shader
}
