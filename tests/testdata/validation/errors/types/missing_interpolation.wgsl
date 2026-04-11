// @test: errors/types/missing-interpolation
// @expect-error E0406 "requires @interpolate(flat)"
// Integer fragment input missing @interpolate(flat)

struct FragInput {
    @location(0) color: vec4f,
    @location(1) id: u32,
}

@fragment
fn main(input: FragInput) -> @location(0) vec4f {
    return input.color;
}
