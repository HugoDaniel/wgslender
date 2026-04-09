// @test: errors/calls/builtin-wrong-args
// @expect-error E0203
// Wrong argument type for builtin function

@fragment
fn main() {
    let x = sin(true);  // Error: sin expects numeric type, not bool
}
