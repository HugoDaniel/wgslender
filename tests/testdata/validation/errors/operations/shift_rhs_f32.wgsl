// @test: errors/operations/shift-rhs-f32
// @expect-error E0200 "expected integer scalar"
// Concrete f32 RHS is rejected at the sub-expression.

@compute @workgroup_size(1)
fn main() {
    let f: f32 = 1.0;
    let _x = 1u << f;
}
