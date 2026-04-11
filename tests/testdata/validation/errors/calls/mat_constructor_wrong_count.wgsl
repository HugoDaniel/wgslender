// @test: errors/calls/mat-constructor-wrong-count
// @expect-error E0202 "scalar constructor requires 4 values, got 3"
// Matrix constructor with wrong number of scalar args

@fragment
fn main() {
    let m = mat2x2f(1.0, 2.0, 3.0);
}
