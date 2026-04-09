// @test: types/incr-decr-valid
// @expect-valid
// @spec-ref: 7.2 "Increment/Decrement Statement"
// Valid increment/decrement on concrete integer scalars (i32, u32).

@fragment
fn main() -> @location(0) vec4f {
    var x : i32 = 0;
    x++;
    x--;

    var y : u32 = 5u;
    y++;
    y--;

    return vec4f(f32(x), f32(y), 0.0, 1.0);
}
