// @test: types/vector-constructors-valid
// @expect-valid
// @spec-ref: 6.2.10 "Value Constructor Built-in Functions"
// Valid vector constructor forms per WGSL spec.

@fragment
fn main() -> @location(0) vec4f {
    // Zero-value constructors
    let z2 = vec2f();
    let z3 = vec3f();
    let z4 = vec4f();

    // Splat constructors (1 scalar → all components)
    let s2 = vec2f(1.0);
    let s3 = vec3f(1.0);
    let s4 = vec4f(1.0);

    // Component-wise constructors (N scalars for vecN)
    let c2 = vec2f(1.0, 2.0);
    let c3 = vec3f(1.0, 2.0, 3.0);
    let c4 = vec4f(1.0, 2.0, 3.0, 4.0);

    // Copy/convert constructors (vecN from vecN)
    let cp3 = vec3f(c3);
    let cp4 = vec4f(c4);

    // Mixed constructors: vec3 from vec2 + scalar
    let m3a = vec3f(c2, 3.0);
    let m3b = vec3f(1.0, c2);

    // Mixed constructors: vec4 from various combinations
    let m4a = vec4f(c2, c2);           // vec2 + vec2
    let m4b = vec4f(c3, 4.0);          // vec3 + scalar
    let m4c = vec4f(1.0, c3);          // scalar + vec3
    let m4d = vec4f(c2, 3.0, 4.0);    // vec2 + 2 scalars
    let m4e = vec4f(1.0, c2, 4.0);    // scalar + vec2 + scalar
    let m4f = vec4f(1.0, 2.0, c2);    // 2 scalars + vec2

    // Integer and unsigned vector constructors (AbstractInt → any numeric)
    let i2 = vec2i(1, 2);
    let i3 = vec3i(1, 2, 3);
    let u4 = vec4u(1, 2, 3, 4);

    // AbstractInt converts to f32 in vec constructor
    let ai_f = vec3f(1, 2, 3);

    // AbstractInt splat in integer vectors
    let si = vec3i(0);
    let su = vec3u(0);

    // Explicit scalar conversion then vector construction
    let ex = vec4f(f32(1i), f32(2i), 0.0, 1.0);

    return c4;
}
