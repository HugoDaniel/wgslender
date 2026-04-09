// @test: errors/symbols/undefined-variable-expr
// @expect-error E0100 "undefined"
// Undefined variable in expression

@fragment
fn main() {
    let y = x + 1;  // Error: 'x' is not defined
}
