// @test: errors/declarations/var-in-workgroup-size
// @expect-error E0315 "must be const-expressions or override-expressions"
// var<private> reference in @workgroup_size is runtime expression

var<private> sz: u32 = 8;

@compute @workgroup_size(sz)
fn main() {}
