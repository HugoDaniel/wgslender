// @test: errors/types/index-inner-binary-float
// @expect-error E0200 "expected integer scalar"
// Nested float expression as index: the whole `1.0 + 2.0` subtree is the
// offending span — `.integer_scalar` fires at the outer binary, not inside.

var<private> a: array<f32, 8>;

@compute @workgroup_size(1)
fn main() {
    let _x = a[1.0 + 2.0];
}
