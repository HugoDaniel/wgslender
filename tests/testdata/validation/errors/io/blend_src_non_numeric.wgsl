// @test: errors/io/blend-src-non-numeric
// @expect-error E0404 "@location requires numeric scalar or numeric vector type"
// spec-ref: §12.3.1.2 Input-output Locations (dual-source blending)

enable dual_source_blending;

struct Outputs {
    @location(0) @blend_src(0) a : mat2x2<f32>,
    @location(0) @blend_src(1) b : mat2x2<f32>,
}

@fragment
fn main() -> Outputs {
    return Outputs(mat2x2<f32>(), mat2x2<f32>());
}
