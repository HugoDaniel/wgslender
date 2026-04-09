// @test: errors/types/invalid-conversion
// @expect-error E0209 "cannot convert"
// Cannot convert vector to scalar

@fragment
fn main() -> @location(0) vec4f {
    let v = vec3f(1.0, 2.0, 3.0);
    let x = f32(v);
    return vec4f(1.0);
}
