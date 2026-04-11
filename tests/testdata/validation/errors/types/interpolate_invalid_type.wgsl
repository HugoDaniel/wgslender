// @test: errors/types/interpolate-invalid-type
// @expect-error E0405 "invalid interpolation type"
// Unknown interpolation type 'cubic'

struct FragIn {
    @location(0) @interpolate(cubic) val: f32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(input.val);
}
