// @test: mul/scalar-vec3/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Scalar * Vector multiplication: f32 * vec3<f32> -> vec3<f32>

@fragment
fn main() {
    let s = 2.0;
    let v = vec3<f32>(1.0, 2.0, 3.0);
    let x = s * v;
}
