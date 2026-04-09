// @test: types/entry-point-vertex
// @expect-valid
// @spec-ref: 11.1 "Entry Points"
// Vertex entry point with proper I/O

struct VertexInput {
    @location(0) position : vec4<f32>,
    @location(1) normal : vec3<f32>,
    @location(2) uv : vec2<f32>,
}

struct VertexOutput {
    @builtin(position) position : vec4<f32>,
    @location(0) normal : vec3<f32>,
    @location(1) uv : vec2<f32>,
}

@vertex
fn main(input : VertexInput) -> VertexOutput {
    var output : VertexOutput;
    output.position = input.position;
    output.normal = input.normal;
    output.uv = input.uv;
    return output;
}
