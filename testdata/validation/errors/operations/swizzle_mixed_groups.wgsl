// @test: errors/operations/swizzle-mixed-groups
// @expect-error E0206 "mixes"
// Swizzle mixes xyzw and rgba groups

@fragment
fn main() -> @location(0) vec4f {
    let v = vec3f(1.0, 2.0, 3.0);
    let a = v.xgb;
    return vec4f(1.0);
}
