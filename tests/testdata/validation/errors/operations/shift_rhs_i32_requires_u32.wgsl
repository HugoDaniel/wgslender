// @test: errors/operations/shift-rhs-i32-requires-u32
// @expect-error E0201 "shift amount must be 'u32'"
// i32 RHS passes the `.integer_scalar` expectation but still fails the
// later u32 narrowing — verifies the two checks layer correctly.

@compute @workgroup_size(1)
fn main() {
    let i: i32 = 1;
    let _x = 1u << i;
}
