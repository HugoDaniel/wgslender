// @test: errors/calls/arg-type-mismatch
// @expect-error E0204 "not a function"
// Wrong argument type in function call (currently reports undefined function)

fn foo(a : i32, b : f32) {
}

@fragment
fn main() {
    foo(true, 1.0);  // Error: expected i32, got bool (TODO: improve error)
}
