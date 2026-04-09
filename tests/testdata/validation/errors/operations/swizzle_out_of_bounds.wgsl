// @test: errors/operations/swizzle-out-of-bounds
// @expect-error E0206 "out of bounds"
// Swizzle component accesses past vector width

@fragment
fn main() -> @location(0) vec4f {
    let v = vec2f(1.0, 2.0);
    let a = v.z;
    return vec4f(1.0);
}
