// @test: errors/io/builtin-frag-depth-wrong-type-vec4
// @expect-error E0200 "@builtin(frag_depth) requires type 'f32'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@fragment
fn main() -> @builtin(frag_depth) vec4<f32> {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
