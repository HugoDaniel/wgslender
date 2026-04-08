// @test: errors/declarations/duplicate-location
// @expect-error E0602 "duplicate output @location"
// Duplicate @location values in entry point output struct

struct FragOutput {
    @location(0) color1: vec4f,
    @location(0) color2: vec4f,
}

@fragment
fn main() -> FragOutput {
    return FragOutput(vec4f(1.0), vec4f(0.0));
}
