// @test: errors/types/interpolate-linear-first
// @expect-error E0405 "must be 'center', 'centroid', or 'sample'"
// @interpolate(linear, first) is invalid — first only valid with flat

struct FragIn {
    @location(0) @interpolate(linear, first) val: f32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(input.val);
}
