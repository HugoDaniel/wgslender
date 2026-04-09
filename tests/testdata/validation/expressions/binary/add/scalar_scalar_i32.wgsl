// @test: add/scalar-scalar/i32
// @expect-valid
// @spec-ref: 6.8.7 "Arithmetic Expressions"
// Scalar + Scalar addition: i32 + i32 -> i32

@fragment
fn main() {
    let a = 1i;
    let b = 2i;
    let c = a + b;
}
