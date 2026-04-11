// @test: errors/declarations/runtime-workgroup-size
// @expect-error E0315 "must be const-expressions or override-expressions"
// Runtime expression in @workgroup_size

var<private> x: u32 = 1;

@compute @workgroup_size(x)
fn main() {}
