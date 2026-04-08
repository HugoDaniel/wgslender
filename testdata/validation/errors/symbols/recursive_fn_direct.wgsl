// @test: errors/symbols/recursive-fn-direct
// @expect-error E0103 "recursive"
// Direct function recursion

fn foo() {
    foo();
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
