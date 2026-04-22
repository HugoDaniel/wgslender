// @test: errors/types/index-f32-var
// @expect-error E0200 "expected integer scalar"
// Concrete f32 variable as array index rejected at the index sub-expression.

var<private> a: array<f32, 4>;

@compute @workgroup_size(1)
fn main() {
    let f: f32 = 1.0;
    let _x = a[f];
}
