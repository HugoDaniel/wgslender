// @test: errors/operations/shift-rhs-bool
// @expect-error E0200 "expected integer scalar"
// Bool RHS is rejected.

@compute @workgroup_size(1)
fn main() {
    let _x = 1u << true;
}
