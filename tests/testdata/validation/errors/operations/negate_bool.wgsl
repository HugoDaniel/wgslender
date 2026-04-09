// @test: errors/operations/negate-bool
// @expect-error E0201 "negation"
// Negation not valid on bool

@fragment
fn main() {
    let x = -true;  // Error: negation not valid for bool
}
