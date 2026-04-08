// @test: mul/mat-scalar/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Matrix * Scalar multiplication: mat4x4<f32> * f32 -> mat4x4<f32>

struct Uniforms {
    matrix : mat4x4<f32>,
    scale : f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@fragment
fn main() {
    let scaled = uniforms.matrix * uniforms.scale;
}
