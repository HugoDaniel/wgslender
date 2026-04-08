// @test: errors/symbols/undefined-function
// @expect-error E0204 "not a function"
// Undefined function call

@fragment
fn main() {
    let x = foo();  // Error: 'foo' is not a function
}
