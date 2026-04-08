// @test: errors/symbols/var-different-scope
// @expect-error E0100 "undefined"
// Variable used in different scope block

@fragment
fn main() {
    {
        var a : f32 = 2.0;
    }
    {
        a = 3.14;  // Error: 'a' is not visible in this scope
    }
}
