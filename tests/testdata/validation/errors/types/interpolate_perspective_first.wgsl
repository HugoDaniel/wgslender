// @test: errors/types/interpolate-perspective-first
// @expect-error E0405 "must be 'center', 'centroid', or 'sample'"
// @interpolate(perspective, first) is invalid — first only valid with flat

struct FragIn {
    @location(0) @interpolate(perspective, first) val: f32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(input.val);
}
