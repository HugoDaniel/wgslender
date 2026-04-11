// @test: errors/declarations/f16-without-enable
// @expect-error E0900 "requires 'enable f16;'"
// f16 type used without enable directive

var<private> x: f16;

@compute @workgroup_size(1)
fn main() { x = 0.0h; }
