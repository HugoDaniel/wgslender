// @test: uniformity/derivatives-uniform
// @expect-valid
// @spec-ref: 15 "Uniformity"
// Derivative calls in uniform control flow

@group(0) @binding(0) var tex : texture_2d<f32>;
@group(0) @binding(1) var samp : sampler;

@fragment
fn main(@location(0) uv : vec2<f32>) -> @location(0) vec4<f32> {
    // Unconditional derivative calls are OK
    let dx = dpdx(uv.x);
    let dy = dpdy(uv.y);
    let fw = fwidth(uv);

    // Texture sampling (uses implicit derivatives)
    let color = textureSample(tex, samp, uv);

    return color;
}
