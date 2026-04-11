// @test: errors/types/index-out-of-bounds-zero
// @expect-error E0211 "out of bounds"
// Off-by-one: array of 1 element indexed at [1]

var<private> a: array<f32, 1>;

@compute @workgroup_size(1)
fn main() {
    a[1] = 1.0;
}
