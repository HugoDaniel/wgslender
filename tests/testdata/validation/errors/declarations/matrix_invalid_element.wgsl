// @test: errors/declarations/matrix-invalid-element
// @expect-error E0309 "matrix element type must be f32 or f16"
// Spec: matrix element type must be f32, f16, or AbstractFloat.

@fragment
fn main() {
    var m : mat2x2<i32>;
}
