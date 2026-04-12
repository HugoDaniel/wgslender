// @test: types/discard-terminates
// @expect-valid
// discard terminates the invocation — no return needed after it

@fragment
fn main() -> @location(0) vec4f {
    discard;
}
