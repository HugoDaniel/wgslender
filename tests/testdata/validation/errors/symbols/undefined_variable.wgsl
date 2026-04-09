// @test: errors/symbols/undefined-variable
// @expect-error E0100 "undefined"
// Undefined variable in assignment

@fragment
fn main() {
    x = 2;  // Error: 'x' is not defined
}
