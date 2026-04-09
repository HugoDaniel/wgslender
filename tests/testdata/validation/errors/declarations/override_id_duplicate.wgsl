// @test: errors/declarations/override-id-duplicate
// @expect-error E0312 "already used"
// Spec: two override declarations must not use the same @id.

@id(0) override a : f32 = 1.0;
@id(0) override b : i32 = 2;

@compute @workgroup_size(1)
fn main() {
}
