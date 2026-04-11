// @test: errors/calls/scalar-constructor-too-many
// @expect-error E0202 "takes at most 1 argument"
// Scalar constructor with too many arguments

@fragment
fn main() {
    let x = f32(1.0, 2.0);
}
