// @test: errors/declarations/override-id-out-of-range
// @expect-error E0311 "out of range"
// Spec: @id must be 0..65535.

@id(70000) override x : f32 = 1.0;

@compute @workgroup_size(1)
fn main() {
}
