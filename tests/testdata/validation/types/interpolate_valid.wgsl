// @test: types/interpolate-valid
// @expect-valid
// All valid @interpolate combinations

struct FragIn {
    @location(0) @interpolate(perspective, center) a: f32,
    @location(1) @interpolate(linear, sample) b: f32,
    @location(2) @interpolate(flat) c: u32,
    @location(3) @interpolate(flat, first) d: i32,
    @location(4) @interpolate(flat, either) e: u32,
    @location(5) @interpolate(perspective, centroid) f: f32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(input.a);
}
