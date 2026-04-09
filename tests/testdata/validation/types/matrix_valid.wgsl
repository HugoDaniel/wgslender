// @test: types/matrix-valid
// @expect-valid
// @spec-ref: 5.2.5 "Matrix Types"
// Valid matrix types: f32 and f16 element types, plus shorthands.

@fragment
fn main() -> @location(0) vec4f {
    var m1 : mat2x2<f32>;
    var m2 : mat3x3<f32>;
    var m3 : mat4x4<f32>;
    var m4 : mat2x3<f32>;
    var m5 : mat3x4<f32>;
    var m6 : mat2x2f;
    var m7 : mat4x4f;

    m1 = mat2x2(1.0, 0.0, 0.0, 1.0);
    m6 = mat2x2f(1.0, 0.0, 0.0, 1.0);
    return vec4f(m1[0][0]);
}
