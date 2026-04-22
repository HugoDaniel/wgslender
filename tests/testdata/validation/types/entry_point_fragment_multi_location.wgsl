// @test: types/entry-point-fragment-multi-location
// @expect-valid
// spec-ref: §10.2.1 User-defined Inputs and Outputs

struct Outputs {
    @location(0) a : vec4<f32>,
    @location(1) b : vec4<f32>,
    @location(2) c : f32,
}

@fragment
fn main() -> Outputs {
    return Outputs(vec4<f32>(0.0), vec4<f32>(0.0), 0.0);
}
