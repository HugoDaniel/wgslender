// @test: errors/types/switch-duplicate-case
// @expect-error E0306 "duplicate case selector"
// Spec: case selector values must be unique within a switch.

@fragment
fn main() -> @location(0) vec4f {
    var x : i32 = 0;
    switch x {
        case 1: { x = 10; }
        case 1: { x = 20; }
        default: { x = 0; }
    }
    return vec4f(1.0);
}
