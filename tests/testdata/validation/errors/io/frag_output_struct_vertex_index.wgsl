// @test: errors/io/frag-output-struct-vertex-index
// @expect-error E0403 "@builtin(vertex_index) is not valid for fragment shaders"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

struct FragOut {
    @builtin(vertex_index) idx : u32,
    @location(0) color : vec4<f32>,
}

@fragment
fn main() -> FragOut {
    return FragOut(0u, vec4<f32>(1.0));
}
