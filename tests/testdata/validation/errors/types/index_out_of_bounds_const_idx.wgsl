// @test: errors/types/index-out-of-bounds-const-idx
// @expect-error E0211 "out of bounds"
// Const index propagated and detected out of bounds

const IDX = 5;
var<private> a: array<f32, 3>;

@compute @workgroup_size(1)
fn main() {
    a[IDX] = 1.0;
}
