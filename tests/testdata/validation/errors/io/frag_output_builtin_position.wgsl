// @test: errors/io/frag-output-builtin-position
// @expect-error E0403 "@builtin(position) is not valid for fragment shaders"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@fragment
fn main() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
