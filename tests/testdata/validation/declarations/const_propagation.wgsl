// @test: declarations/const-propagation
// @expect-valid
// Const values propagate through identifiers for array sizes and attributes

const N = 4;
const M = 8;
var<private> a: array<f32, N>;
var<private> b: array<vec3f, M>;

@compute @workgroup_size(1)
fn main() {
    a[0] = 1.0;
    a[3] = 2.0;
    b[7] = vec3f(1.0);
}
