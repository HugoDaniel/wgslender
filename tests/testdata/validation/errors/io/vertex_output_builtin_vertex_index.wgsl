// @test: errors/io/vertex-output-builtin-vertex-index
// @expect-error E0403 "@builtin(vertex_index) is not valid for vertex shaders"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

struct VertexOutput {
    @builtin(position) pos : vec4<f32>,
    @builtin(vertex_index) idx : u32,
}

@vertex
fn main() -> VertexOutput {
    return VertexOutput(vec4<f32>(0.0), 0u);
}
