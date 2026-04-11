// @test: declarations/const-propagation-negated
// @expect-valid
// Negated const values propagate correctly

const NEG = -3;
const POS = -NEG;
var<private> a: array<f32, POS>;

@compute @workgroup_size(1)
fn main() {
    a[0] = 1.0;
    a[2] = 3.0;
}
