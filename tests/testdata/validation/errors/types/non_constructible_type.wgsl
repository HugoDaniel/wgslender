// @test: errors/types/non-constructible-type
// @expect-error E0200 "not constructible"
// Atomic types are not constructible

@compute @workgroup_size(1)
fn main() {
    let x = atomic<u32>();
}
