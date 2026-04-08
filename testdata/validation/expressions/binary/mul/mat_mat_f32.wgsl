// @test: mul/mat-mat/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Matrix * Matrix multiplication: mat4x4<f32> * mat4x4<f32> -> mat4x4<f32>

struct Matrices {
    a : mat4x4<f32>,
    b : mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> matrices: Matrices;

@fragment
fn main() {
    let result = matrices.a * matrices.b;
}
