// @test: errors/io/blend-src-on-vertex-output
// @expect-error E0400 "@blend_src is only valid on fragment outputs"
// spec-ref: §11.3 blend_src

struct VOut {
    @builtin(position) pos : vec4<f32>,
    @location(0) @blend_src(0) color : vec4<f32>,
}

@vertex
fn main() -> VOut {
    var o : VOut;
    o.pos = vec4<f32>(0.0);
    return o;
}
