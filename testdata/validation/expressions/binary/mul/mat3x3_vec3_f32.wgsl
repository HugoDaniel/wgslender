// @test: mul/mat3x3-vec3/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Matrix * Vector multiplication: mat3x3<f32> * vec3<f32> -> vec3<f32>

struct S {
    matrix : mat3x3<f32>,
    vector : vec3<f32>,
}

@group(0) @binding(0) var<uniform> data: S;

@fragment
fn main() {
    let x = data.matrix * data.vector;
}
