// @test: builtins/texture-sample
// @expect-valid
// @spec-ref: 17.6 "Texture Built-in Functions"
// Texture sampling operations

@group(0) @binding(0) var tex : texture_2d<f32>;
@group(0) @binding(1) var samp : sampler;

@fragment
fn main(@location(0) uv : vec2<f32>) -> @location(0) vec4<f32> {
    let color = textureSample(tex, samp, uv);
    return color;
}
