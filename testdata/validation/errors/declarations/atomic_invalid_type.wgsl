// @test: errors/declarations/atomic-invalid-type
// @expect-error E0308 "atomic type requires i32 or u32"
// Spec: atomic type element must be i32 or u32 only.

var<workgroup> a : atomic<f32>;

@compute @workgroup_size(1)
fn main() {
}
