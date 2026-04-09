// @test: declarations/let-basic
// @expect-valid
// @spec-ref: 6.2.3 "Let Declarations"
// Basic let declarations (immutable)

@fragment
fn main() {
    let a = 42;
    let b = 3.14;
    let c : f32 = 2.5;
    let v = vec3<f32>(1.0, 2.0, 3.0);
    let sum = a + 10;
    let scaled = v * 2.0;
}
