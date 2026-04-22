// @test: errors/io/builtin-clip-distances-too-many
// @expect-error E0200 "@builtin(clip_distances) requires array size ≤ 8"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

enable clip_distances;

struct VOut {
    @builtin(position) pos : vec4<f32>,
    @builtin(clip_distances) clips : array<f32, 16>,
}

@vertex
fn main() -> VOut {
    var o : VOut;
    return o;
}
