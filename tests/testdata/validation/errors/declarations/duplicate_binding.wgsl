// @test: errors/declarations/duplicate-binding
// @expect-error E0804 "already used"
// Two resource variables with same @group/@binding pair

struct Data { value: f32 }

@group(0) @binding(0) var<uniform> a: Data;
@group(0) @binding(0) var<uniform> b: Data;

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
