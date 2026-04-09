// @test: mul/vec-vec/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Vector * Vector component-wise multiplication: vec3<f32> * vec3<f32> -> vec3<f32>

@fragment
fn main() {
    let a = vec3<f32>(1.0, 2.0, 3.0);
    let b = vec3<f32>(4.0, 5.0, 6.0);
    let c = a * b;
}
