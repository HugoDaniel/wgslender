// @test: uniformity/user-var-named-position
// @expect-valid
// @spec-ref: 15 "Uniformity"
// @blocked-on: U1
// False-positive surface #1: a user `let` named `position` (a builtin name)
// taints the condition purely by string match, so today this misfires E0702 on
// the guarded textureSample. INVALID today; must become VALID once idents are
// resolved through their SymbolIndex rather than compared by name (U1).

@group(0) @binding(0) var tex : texture_2d<f32>;
@group(0) @binding(1) var samp : sampler;

@fragment
fn main() -> @location(0) vec4<f32> {
    let position = vec2<f32>(0.5, 0.5);
    if (position.x > 0.0) {
        return textureSample(tex, samp, position);
    }
    return vec4<f32>(0.0);
}
