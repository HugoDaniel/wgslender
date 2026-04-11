// @test: types/matrix-constructors-valid
// @expect-valid
// @spec-ref: 6.2.10 "Value Constructor Built-in Functions"
// Valid matrix constructor forms per WGSL spec.

@fragment
fn main() -> @location(0) vec4f {
    // Zero-value constructors
    let z22 = mat2x2f();
    let z33 = mat3x3f();
    let z44 = mat4x4f();

    // Scalar constructors (C*R values)
    let s22 = mat2x2f(1.0, 0.0, 0.0, 1.0);
    let s23 = mat2x3f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
    let s32 = mat3x2f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
    let s33 = mat3x3f(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);

    // Column vector constructors
    let v2a = vec2f(1.0, 0.0);
    let v2b = vec2f(0.0, 1.0);
    let cv22 = mat2x2f(v2a, v2b);

    let v3a = vec3f(1.0, 0.0, 0.0);
    let v3b = vec3f(0.0, 1.0, 0.0);
    let v3c = vec3f(0.0, 0.0, 1.0);
    let cv33 = mat3x3f(v3a, v3b, v3c);

    let cv23 = mat2x3f(v3a, v3b);

    return vec4f(s22[0][0]);
}
