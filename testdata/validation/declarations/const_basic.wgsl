// @test: declarations/const-basic
// @expect-valid
// @spec-ref: 6.2.1 "Const Declarations"
// Module-scope and function-scope const declarations

const PI : f32 = 3.14159265359;
const TWO_PI = PI * 2.0;
const DIMENSIONS = vec3<i32>(8, 8, 8);

@fragment
fn main() {
    let x = PI * 2.0;
    let y = TWO_PI;
    let dim = DIMENSIONS.x;
}
