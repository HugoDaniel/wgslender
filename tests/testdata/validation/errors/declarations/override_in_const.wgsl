// @test: errors/declarations/override-in-const
// @expect-error E0302 "references an override"
// const initializer must not reference an override

override N: u32 = 8;
const M = N;

@compute @workgroup_size(1)
fn main() {
}
