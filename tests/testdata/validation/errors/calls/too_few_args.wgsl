// @test: errors/calls/too-few-args
// @expect-error E0204 "not a function"
// Too few arguments in function call (currently reports undefined function)

fn foo(a : i32, b : f32) {
}

@fragment
fn main() {
    foo(1);  // Error: expected 2 arguments (TODO: improve error)
}
