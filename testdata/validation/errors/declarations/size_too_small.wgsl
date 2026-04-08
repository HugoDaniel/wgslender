// @test: errors/declarations/size-too-small
// @expect-error E0400 "less than"
// @size must be >= the byte size of the type

struct Data {
    @size(2) value: f32,
}

@group(0) @binding(0) var<uniform> d: Data;

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
