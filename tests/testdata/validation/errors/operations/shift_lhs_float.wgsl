// @test: errors/operations/shift-lhs-float
// @expect-error E0201 "requires integer left operand"
// Shift LHS still uses `.none` (vectors are legal LHS in WGSL), so this
// fires E0201 in the binary handler — not E0200 from `.integer_scalar`.

@compute @workgroup_size(1)
fn main() {
    let _x = 1.0 << 1u;
}
