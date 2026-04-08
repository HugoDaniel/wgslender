// @test: errors/symbols/use-before-decl-let
// @expect-error E0102 "before"
// Let used before its declaration in function body

@fragment
fn main() -> @location(0) vec4f {
    let y = x;
    let x = 5;
    return vec4f(1.0);
}
