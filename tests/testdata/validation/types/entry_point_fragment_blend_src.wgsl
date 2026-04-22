// @test: types/entry-point-fragment-blend-src
// @expect-valid
// @spec-ref: §12.3.1.2 Input-output Locations (dual-source blending)

enable dual_source_blending;

struct DualOut {
    @location(0) @blend_src(0) color : vec4<f32>,
    @location(0) @blend_src(1) blend : vec4<f32>,
}

@fragment
fn main() -> DualOut {
    return DualOut(vec4<f32>(1.0), vec4<f32>(0.5));
}
