// @test: errors/operations/sub-incompatible-types
// @expect-error E0201 "arithmetic"
// Subtraction with incompatible types

@fragment
fn main() {
    let x = vec3<f32>(1.0) - 1u;  // Error: can't subtract u32 from vec3<f32>
}
