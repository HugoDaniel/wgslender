// @test: uniformity/texture-dimensions-condition
// @expect-valid
// @spec-ref: 15 "Uniformity"
// @blocked-on: U1
// False-positive surface #2: `textureDimensions` is a `.texture`-kind builtin
// but its result is perfectly uniform (uniformity == .none). Today the blanket
// "texture-kind call => non-uniform" taints the condition and misfires E0702 on
// the guarded textureSample. INVALID today; must become VALID once the blanket
// is replaced by "uniform iff args uniform" (U1). The call is inline in the
// condition (not let-bound) to exercise the `.call` taint path directly.

@group(0) @binding(0) var tex : texture_2d<f32>;
@group(0) @binding(1) var samp : sampler;

@fragment
fn main(@location(0) uv : vec2<f32>) -> @location(0) vec4<f32> {
    if (textureDimensions(tex).x > 0u) {
        return textureSample(tex, samp, uv);
    }
    return vec4<f32>(0.0);
}
