// @test: errors/types/index-negative
// @expect-error E0211 "out of bounds"
// Negative array index

var<private> a: array<f32, 5>;

@compute @workgroup_size(1)
fn main() {
    a[-1] = 1.0;
}
