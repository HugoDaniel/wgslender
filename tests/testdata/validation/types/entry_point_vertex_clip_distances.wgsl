// @test: types/entry-point-vertex-clip-distances
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs

enable clip_distances;

struct VOut {
    @builtin(position) pos : vec4<f32>,
    @builtin(clip_distances) clips : array<f32, 8>,
}

@vertex
fn main() -> VOut {
    var o : VOut;
    o.pos = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    return o;
}
