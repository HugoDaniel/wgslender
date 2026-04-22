// @test: errors/io/blend-src-type-mismatch
// @expect-error E0602 "@blend_src pair at @location(0) must share a type"
// spec-ref: §12.3.1.2 Input-output Locations (dual-source blending)

struct FragOut {
    @location(0) @blend_src(0) a : vec4<f32>,
    @location(0) @blend_src(1) b : f32,
}

@fragment
fn main() -> FragOut {
    return FragOut(vec4<f32>(1.0), 0.5);
}
