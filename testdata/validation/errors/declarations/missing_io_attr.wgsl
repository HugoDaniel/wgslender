// @test: errors/declarations/missing-io-attr
// @expect-error E0602 "must have @builtin or @location"
// Entry point struct member without @builtin or @location

struct VertexOutput {
    @builtin(position) pos: vec4f,
    uv: vec2f,
}

@vertex
fn main() -> VertexOutput {
    return VertexOutput(vec4f(0.0), vec2f(0.0));
}
