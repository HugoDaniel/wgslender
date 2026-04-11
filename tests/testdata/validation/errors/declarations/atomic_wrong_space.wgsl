// @test: errors/declarations/atomic-wrong-space
// @expect-error E0308 "must be in 'workgroup' or 'storage'"
// Atomic types must be in workgroup or storage(read_write) address space

var<private> counter: atomic<u32>;

@compute @workgroup_size(1)
fn main() {}
