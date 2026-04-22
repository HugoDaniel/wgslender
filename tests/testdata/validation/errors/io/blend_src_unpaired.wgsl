// @test: errors/io/blend-src-unpaired
// @expect-error E0602 "missing its paired @blend_src"
// spec-ref: §12.3.1.2 Input-output Locations (dual-source blending)

struct FragOut {
    @location(0) @blend_src(0) color : vec4<f32>,
}

@fragment
fn main() -> FragOut {
    return FragOut(vec4<f32>(1.0));
}
