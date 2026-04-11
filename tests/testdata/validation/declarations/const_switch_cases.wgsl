// @test: declarations/const-switch-cases
// @expect-valid
// Const-declared values used as switch case selectors

const CASE_A: i32 = 1;
const CASE_B: i32 = 2;
const CASE_C: i32 = 3;

@compute @workgroup_size(1)
fn main() {
    var x: i32 = 2;
    switch x {
        case CASE_A: { x = 10; }
        case CASE_B: { x = 20; }
        case CASE_C: { x = 30; }
        default: { x = 0; }
    }
}
