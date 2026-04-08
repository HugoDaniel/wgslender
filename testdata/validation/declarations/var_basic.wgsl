// @test: declarations/var-basic
// @expect-valid
// @spec-ref: 6.2.2 "Variable Declarations"
// Basic var declarations with various types

@fragment
fn main() {
    var a : i32;
    var b : f32 = 1.0;
    var c = 42;  // inferred i32
    var d = 3.14;  // inferred f32
    var v : vec3<f32> = vec3<f32>(1.0, 2.0, 3.0);
    var m : mat2x2<f32> = mat2x2<f32>(1.0, 0.0, 0.0, 1.0);

    a = 10;
    b = b + 1.0;
}
