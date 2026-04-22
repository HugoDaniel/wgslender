// @test: errors/io/builtin-vertex-index-wrong-type-i32
// @expect-error E0200 "@builtin(vertex_index) requires type 'u32'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@vertex
fn main(@builtin(vertex_index) idx : i32) -> @builtin(position) vec4<f32> {
    return vec4<f32>(f32(idx), 0.0, 0.0, 1.0);
}
