// @test: errors/types/runtime-array-value
// @expect-error E0200 "runtime-sized array"
// Runtime-sized array cannot be used as function return type

fn foo() -> array<f32> {
    return array<f32>();
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
