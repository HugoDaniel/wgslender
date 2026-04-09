// @test: mul/vec3-scalar/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Vector * Scalar multiplication: vec3<f32> * f32 -> vec3<f32>

@fragment
fn main() {
    let v = vec3<f32>(1.0, 2.0, 3.0);
    let s = 2.0;
    let x = v * s;
}
