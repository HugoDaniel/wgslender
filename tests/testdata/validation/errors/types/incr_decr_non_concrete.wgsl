// @test: errors/types/incr-decr-non-concrete
// @expect-error E0200 "concrete integer scalar"
// Spec: increment/decrement operand must be concrete integer scalar (i32/u32).

@fragment
fn main() -> @location(0) vec4f {
    var x : f32 = 1.0;
    x++;
    return vec4f(1.0);
}
