// @test: types/index-bounds-valid
// @expect-valid
// All index accesses within bounds

var<private> a: array<f32, 5>;
var<private> v2: vec2f;
var<private> v4: vec4f;
var<private> m: mat2x2f;

@compute @workgroup_size(1)
fn main() {
    // Array: valid range [0, 4]
    a[0] = 1.0;
    a[4] = 5.0;
    // vec2: valid range [0, 1]
    v2[0] = 1.0;
    v2[1] = 2.0;
    // vec4: valid range [0, 3]
    v4[0] = 1.0;
    v4[3] = 4.0;
    // mat2x2: valid range [0, 1] (column index)
    let col0 = m[0];
    let col1 = m[1];
}
