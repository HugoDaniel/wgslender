// @test: types/entry-point-fragment-frag-depth
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs

struct FragOut {
    @builtin(frag_depth) depth : f32,
    @location(0) color : vec4<f32>,
}

@fragment
fn main() -> FragOut {
    return FragOut(0.5, vec4<f32>(1.0, 0.0, 0.0, 1.0));
}
