// @test: types/entry-point-fragment
// @expect-valid
// @spec-ref: 11.1 "Entry Points"
// Fragment entry point with proper I/O

struct FragmentInput {
    @location(0) normal : vec3<f32>,
    @location(1) uv : vec2<f32>,
}

@fragment
fn main(input : FragmentInput) -> @location(0) vec4<f32> {
    let color = vec3<f32>(input.normal * 0.5 + 0.5);
    return vec4<f32>(color, 1.0);
}
