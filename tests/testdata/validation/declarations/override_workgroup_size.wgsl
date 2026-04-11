// @test: declarations/override-workgroup-size
// @expect-valid
// Override expression is valid in @workgroup_size

override WG: u32 = 64;

@compute @workgroup_size(WG)
fn main() {}
