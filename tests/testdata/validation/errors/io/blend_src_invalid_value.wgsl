// @test: errors/io/blend-src-invalid-value
// @expect-error E0400 "@blend_src value must be 0 or 1"
// spec-ref: §11.3 blend_src

struct FragOut {
    @location(0) @blend_src(0) a : vec4<f32>,
    @location(0) @blend_src(2) b : vec4<f32>,
}

@fragment
fn main() -> FragOut {
    return FragOut(vec4<f32>(1.0), vec4<f32>(0.5));
}
