// @test: errors/declarations/duplicate-var
// @expect-error E0101 "redeclaration"
// Duplicate variable declaration in same scope

@fragment
fn main() -> @location(0) vec4f {
    var x = 1;
    var x = 2;
    return vec4f(1.0);
}
