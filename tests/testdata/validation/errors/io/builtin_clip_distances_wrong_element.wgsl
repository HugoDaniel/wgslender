// @test: errors/io/builtin-clip-distances-wrong-element
// @expect-error E0200 "@builtin(clip_distances) requires array of f32"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

enable clip_distances;

struct VOut {
    @builtin(position) pos : vec4<f32>,
    @builtin(clip_distances) clips : array<i32, 4>,
}

@vertex
fn main() -> VOut {
    var o : VOut;
    return o;
}
