// @test: errors/types/switch-missing-default
// @expect-error E0307 "default clause"
// Spec: switch statement must have exactly one default clause.

@fragment
fn main() -> @location(0) vec4f {
    var x : i32 = 0;
    switch x {
        case 1: { x = 10; }
        case 2: { x = 20; }
    }
    return vec4f(1.0);
}
