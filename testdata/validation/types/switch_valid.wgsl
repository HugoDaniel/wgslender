// @test: types/switch-valid
// @expect-valid
// @spec-ref: 7.4 "Switch Statement"
// Valid switch statements with distinct cases and default clause.

@fragment
fn main() -> @location(0) vec4f {
    var x : i32 = 0;

    // Basic switch with default
    switch x {
        case 1: { x = 10; }
        case 2: { x = 20; }
        case 3, 4, 5: { x = 30; }
        default: { x = 0; }
    }

    // Switch with u32
    var y : u32 = 0u;
    switch y {
        case 0u: { y = 1u; }
        case 1u: { y = 2u; }
        default: {}
    }

    return vec4f(1.0);
}
