// @test: errors/operations/mul-incompatible-types
// @expect-error E0201 "multiplication"
// Multiplication with incompatible types

@fragment
fn main() {
    let x = vec3<f32>(1.0) * vec2<f32>(1.0);  // Error: incompatible vector sizes
}
