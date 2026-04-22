// @test: errors/operations/shift-rhs-float
// @expect-error E0200 "expected integer scalar"
// Float literal RHS is rejected at the shift RHS sub-expression.

@compute @workgroup_size(1)
fn main() {
    let _x = 1u << 1.5;
}
