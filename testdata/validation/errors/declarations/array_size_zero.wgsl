// @test: errors/declarations/array-size-zero
// @expect-error E0313 "greater than 0"
// Spec: array element count must be > 0.

@fragment
fn main() {
    var a : array<f32, 0>;
}
