// @test: errors/declarations/duplicate-fn
// @expect-error E0101 "redeclaration"
// Duplicate function declaration at module scope

fn foo() -> f32 {
    return 1.0;
}

fn foo() -> f32 {
    return 2.0;
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
