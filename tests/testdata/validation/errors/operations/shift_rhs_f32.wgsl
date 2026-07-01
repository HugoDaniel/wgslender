// @test: errors/operations/shift-rhs-f32
// @expect-error E0201 "shift amount must be 'u32'"
// Concrete f32 RHS is rejected — the shift amount must be u32.

@compute @workgroup_size(1)
fn main() {
    let f: f32 = 1.0;
    let _x = 1u << f;
}
