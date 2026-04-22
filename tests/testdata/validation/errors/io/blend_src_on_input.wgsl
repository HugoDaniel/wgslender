// @test: errors/io/blend-src-on-input
// @expect-error E0400 "@blend_src is only valid on fragment outputs"
// spec-ref: §11.3 blend_src

struct FragIn {
    @location(0) @blend_src(0) color : vec4<f32>,
}

@fragment
fn main(input : FragIn) -> @location(0) vec4<f32> {
    return input.color;
}
