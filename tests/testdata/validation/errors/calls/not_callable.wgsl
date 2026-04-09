// @test: errors/calls/not-callable
// @expect-error E0204 "not a function"
// Calling something that is not a function

@fragment
fn main() {
    var x = 5;
    let y = x(1);  // Error: x is not callable
}
