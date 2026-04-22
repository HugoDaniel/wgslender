// @test: errors/operations/shift-rhs-vector
// @expect-error E0200 "expected integer scalar"
// Integer vector RHS is rejected by `.integer_scalar` — scalar only.

@compute @workgroup_size(1)
fn main() {
    let _x = 1u << vec2<u32>(1u, 2u);
}
