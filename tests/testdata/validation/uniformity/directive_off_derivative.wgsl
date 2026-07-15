// @test: uniformity/directive-off-derivative
// @expect-valid
// @spec-ref: 15 "Uniformity"
// A module-scope `diagnostic(off, derivative_uniformity)` directive suppresses
// the E0700 that a derivative call under non-uniform control flow would raise.

diagnostic(off, derivative_uniformity);

@fragment
fn main(@location(0) uv : vec2<f32>, @builtin(front_facing) ff : bool) -> @location(0) vec4<f32> {
    var r = 0.0;
    if (ff) {
        r = dpdx(uv.x);
    }
    return vec4<f32>(r);
}
