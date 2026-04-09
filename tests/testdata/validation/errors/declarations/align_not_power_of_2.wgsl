// @test: errors/declarations/align-not-power-of-2
// @expect-error E0400 "power of 2"
// @align must be a positive power of 2

struct Data {
    @align(3) value: f32,
}

@group(0) @binding(0) var<uniform> d: Data;

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
