// @test: errors/operations/bitwise-on-float
// @expect-error E0201 "bitwise"
// Bitwise operations not valid on floats

@fragment
fn main() {
    let x = 1.0 & 2.0;  // Error: bitwise AND not valid for f32
}
