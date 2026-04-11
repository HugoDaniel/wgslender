// @test: declarations/const-propagation-workgroup-size
// @expect-valid
// Const value used in @workgroup_size

const WG_X = 8;
const WG_Y = 4;

@compute @workgroup_size(WG_X, WG_Y, 1)
fn main() {}
