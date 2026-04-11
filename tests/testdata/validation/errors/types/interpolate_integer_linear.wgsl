// @test: errors/types/interpolate-integer-linear
// @expect-error E0405 "must use @interpolate(flat)"
// Integer fragment input with @interpolate(linear) is invalid

struct FragIn {
    @location(0) @interpolate(linear) id: u32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(1.0);
}
