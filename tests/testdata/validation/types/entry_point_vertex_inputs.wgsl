// @test: types/entry-point-vertex-inputs
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs
// vertex_index and instance_index with their required u32 type.

@vertex
fn main(
    @builtin(vertex_index) vi : u32,
    @builtin(instance_index) ii : u32,
) -> @builtin(position) vec4<f32> {
    return vec4<f32>(f32(vi + ii), 0.0, 0.0, 1.0);
}
