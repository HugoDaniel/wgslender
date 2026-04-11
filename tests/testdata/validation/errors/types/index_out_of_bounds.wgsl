// @test: errors/types/index-out-of-bounds
// @expect-error E0211 "out of bounds"
// Array index out of bounds detected at compile time

var<private> a: array<f32, 5>;

@compute @workgroup_size(1)
fn main() {
    a[10] = 1.0;
}
