// @test: add/scalar-scalar/f32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Scalar + Scalar addition: f32 + f32 -> f32

@fragment
fn main() {
    let a = 1.0;
    let b = 2.0;
    let c = a + b;
}
