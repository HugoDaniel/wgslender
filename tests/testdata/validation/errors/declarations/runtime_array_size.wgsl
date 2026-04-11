// @test: errors/declarations/runtime-array-size
// @expect-error E0315 "must be a const-expression or override-expression"
// Runtime variable used as array element count

var<private> n: u32 = 5;
var<private> a: array<f32, n>;

@compute @workgroup_size(1)
fn main() {}
