// @test: errors/symbols/undefined-type
// @expect-error E0200 "cannot determine type"
// Undefined type in declaration

@fragment
fn main() {
    var x : MyType;  // Error: 'MyType' is not defined
}
