// @test: errors/calls/vec-constructor-wrong-count
// @expect-error E0202 "requires 2 components, got 3"
// Vector constructor with too many scalar components

@fragment
fn main() {
    let a = vec2f(0.9, 0.8, 0.7);
}
