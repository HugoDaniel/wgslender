// @test: errors/operations/div-incompatible-types
// @expect-error E0201 "division"
// Division with incompatible types

@fragment
fn main() {
    let x = true / 1.0;  // Error: can't divide bool by f32
}
