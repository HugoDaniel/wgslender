// @test: errors/operations/add-incompatible-types
// @expect-error E0201 "arithmetic"
// Addition with incompatible types

@fragment
fn main() {
    let x = 1.0 + true;  // Error: can't add f32 and bool
}
