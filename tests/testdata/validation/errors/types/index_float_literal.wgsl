// @test: errors/types/index-float-literal
// @expect-error E0200 "expected integer scalar"
// Float literal as array index is rejected at the index sub-expression.

var<private> a: array<f32, 4>;

@compute @workgroup_size(1)
fn main() {
    let _x = a[1.5];
}
