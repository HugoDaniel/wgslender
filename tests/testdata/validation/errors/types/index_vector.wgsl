// @test: errors/types/index-vector
// @expect-error E0200 "expected integer scalar"
// Integer vector as array index is rejected — WGSL §6.2.3 requires a scalar.

var<private> a: array<f32, 4>;

@compute @workgroup_size(1)
fn main() {
    let v = vec2<i32>(0, 1);
    let _x = a[v];
}
