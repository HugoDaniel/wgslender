// @test: errors/symbols/var-out-of-scope
// @expect-error E0100 "undefined"
// Variable used outside its scope

@fragment
fn main() {
    if (true) {
        var a : f32 = 2.0;
    }
    a = 3.14;  // Error: 'a' is out of scope
}
