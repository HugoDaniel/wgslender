// @test: errors/types/index-bool
// @expect-error E0200 "expected integer scalar"
// Bool as array index is rejected.

var<private> a: array<f32, 4>;

@compute @workgroup_size(1)
fn main() {
    let _x = a[true];
}
