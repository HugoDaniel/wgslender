// @test: declarations/const-propagation-chain
// @expect-valid
// Chained const references resolve for array sizes

const A = 2;
const B = A;
const C = B;
var<private> x: array<f32, C>;

@compute @workgroup_size(1)
fn main() {
    x[0] = 1.0;
    x[1] = 2.0;
}
