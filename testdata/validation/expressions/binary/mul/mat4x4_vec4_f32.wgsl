// @test: mul/mat4x4-vec4/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Matrix * Vector multiplication: mat4x4<f32> * vec4<f32> -> vec4<f32>

struct Uniforms {
    modelViewProj : mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@vertex
fn main(@location(0) position: vec4<f32>) -> @builtin(position) vec4<f32> {
    return uniforms.modelViewProj * position;
}
