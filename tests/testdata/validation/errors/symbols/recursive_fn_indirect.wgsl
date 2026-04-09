// @test: errors/symbols/recursive-fn-indirect
// @expect-error E0103 "recursive"
// Indirect (mutual) function recursion

fn a() {
    b();
}

fn b() {
    a();
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
