// @test: errors/operations/shift-rhs-bool
// @expect-error E0201 "shift amount must be 'u32'"
// Bool RHS is rejected — the shift amount must be u32.

@compute @workgroup_size(1)
fn main() {
    let _x = 1u << true;
}
