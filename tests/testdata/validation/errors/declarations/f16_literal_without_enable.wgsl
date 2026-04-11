// @test: errors/declarations/f16-literal-without-enable
// @expect-error E0900 "requires 'enable f16;'"
// f16 literal suffix used without enable directive

@compute @workgroup_size(1)
fn main() {
    let x = 1.0h;
}
