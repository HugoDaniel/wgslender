// @test: errors/symbols/use-before-decl-var
// @expect-error E0102 "before"
// Variable used before its declaration in function body

@fragment
fn main() -> @location(0) vec4f {
    let y = x;
    var x = 5;
    return vec4f(1.0);
}
