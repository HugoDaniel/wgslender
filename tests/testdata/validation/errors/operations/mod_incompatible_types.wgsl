// @test: errors/operations/mod-incompatible-types
// @expect-error E0201 "modulo"
// Modulo with incompatible types (bool not allowed)

@fragment
fn main() {
    let x = true % false;  // Error: modulo not valid for bool
}
