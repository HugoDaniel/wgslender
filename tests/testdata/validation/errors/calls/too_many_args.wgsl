// @test: errors/calls/too-many-args
// @expect-error E0204 "not a function"
// Too many arguments in function call (currently reports undefined function)

fn foo(a : i32, b : f32) {
}

@fragment
fn main() {
    foo(1, 1.0, 1.0);  // Error: expected 2 arguments (TODO: improve error)
}
