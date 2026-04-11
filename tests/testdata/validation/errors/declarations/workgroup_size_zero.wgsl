// @test: errors/declarations/workgroup-size-zero
// @expect-error E0400 "must be at least 1"
// @workgroup_size dimensions must be positive

@compute @workgroup_size(0)
fn main() {}
