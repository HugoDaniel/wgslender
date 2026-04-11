// @test: errors/types/index-out-of-bounds-const
// @expect-error E0211 "out of bounds"
// Const-propagated array size with out-of-bounds index

const N = 4;
var<private> a: array<f32, N>;

@compute @workgroup_size(1)
fn main() {
    a[4] = 1.0;
}
