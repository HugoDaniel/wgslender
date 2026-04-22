// @test: errors/io/vertex-input-frag-depth
// @expect-error E0403 "@builtin(frag_depth) is not valid for vertex shaders"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@vertex
fn main(@builtin(frag_depth) d : f32) -> @builtin(position) vec4<f32> {
    return vec4<f32>(d, 0.0, 0.0, 1.0);
}
