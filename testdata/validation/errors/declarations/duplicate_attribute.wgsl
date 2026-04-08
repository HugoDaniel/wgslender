// @test: errors/declarations/duplicate-attribute
// @expect-error E0401 "duplicate attribute"
// Duplicate attribute on declaration

struct Data { value: f32 }

@group(0) @group(1) @binding(0) var<uniform> x: Data;

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
