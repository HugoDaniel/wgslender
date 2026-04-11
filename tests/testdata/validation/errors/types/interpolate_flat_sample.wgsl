// @test: errors/types/interpolate-flat-sample
// @expect-error E0405 "must be 'first' or 'either'"
// @interpolate(flat, sample) is invalid — flat only accepts first/either

struct FragIn {
    @location(0) @interpolate(flat, sample) id: u32,
}

@fragment
fn main(input: FragIn) -> @location(0) vec4f {
    return vec4f(1.0);
}
