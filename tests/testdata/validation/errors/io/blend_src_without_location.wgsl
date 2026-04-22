// @test: errors/io/blend-src-without-location
// @expect-error E0400 "@blend_src requires a @location attribute"
// spec-ref: §11.3 blend_src

struct FragOut {
    @blend_src(0) color : vec4<f32>,
    @blend_src(1) blend : vec4<f32>,
}

@fragment
fn main() -> FragOut {
    return FragOut(vec4<f32>(1.0), vec4<f32>(0.5));
}
