// @test: errors/io/builtin-position-wrong-type-vec3
// @expect-error E0200 "@builtin(position) requires type 'vec4<f32>'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@vertex
fn main() -> @builtin(position) vec3<f32> {
    return vec3<f32>(0.0, 0.0, 0.0);
}
