// @test: errors/types/interpolate-perspective-either
// @expect-error E0405 "must be 'center', 'centroid', or 'sample'"
// @interpolate(perspective, either) is invalid — either only valid with flat

struct FragIn {
    @location(0) @interpolate(perspective, either) val: f32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(input.val);
}
