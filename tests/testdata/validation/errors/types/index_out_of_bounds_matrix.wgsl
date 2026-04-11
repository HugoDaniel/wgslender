// @test: errors/types/index-out-of-bounds-matrix
// @expect-error E0211 "out of bounds"
// Matrix column index out of bounds

var<private> m: mat2x2f;

@compute @workgroup_size(1)
fn main() {
    let col = m[2];
}
