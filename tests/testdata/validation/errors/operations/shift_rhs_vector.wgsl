// @test: errors/operations/shift-rhs-vector
// @expect-error E0201 "shift amount must be 'u32'"
// A scalar LHS requires a scalar u32 shift amount — a vector RHS is a shape mismatch.

@compute @workgroup_size(1)
fn main() {
    let _x = 1u << vec2<u32>(1u, 2u);
}
