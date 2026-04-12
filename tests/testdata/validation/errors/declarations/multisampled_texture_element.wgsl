// @test: errors/declarations/multisampled-texture-element
// @expect-error E0200 "texture element type must be f32, i32, or u32"
// Multisampled texture element type must be f32, i32, or u32

@group(0) @binding(0) var t: texture_multisampled_2d<bool>;

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(0.0);
}
