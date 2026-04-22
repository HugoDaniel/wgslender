// @test: types/entry-point-fragment-all-inputs
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs

struct FragIn {
    @builtin(position) pos : vec4<f32>,
    @builtin(front_facing) ff : bool,
    @builtin(sample_index) si : u32,
    @builtin(sample_mask) sm : u32,
}

@fragment
fn main(input : FragIn) -> @location(0) vec4<f32> {
    let mask = f32(input.sm);
    return select(vec4<f32>(0.0), input.pos, input.ff) + vec4<f32>(0.0, 0.0, 0.0, mask);
}
