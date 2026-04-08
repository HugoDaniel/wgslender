// @test: types/array-basic
// @expect-valid
// @spec-ref: 5.4 "Array Types"
// Basic array usage

struct Uniforms {
    data : array<vec4<f32>, 16>,
}

@group(0) @binding(0) var<uniform> uniforms : Uniforms;

@fragment
fn main() {
    let first = uniforms.data[0];
    let last = uniforms.data[15];
    var arr : array<f32, 4>;
    arr[0] = 1.0;
    arr[1] = 2.0;
    arr[2] = 3.0;
    arr[3] = 4.0;
}
