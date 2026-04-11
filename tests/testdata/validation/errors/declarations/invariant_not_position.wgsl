// @test: errors/declarations/invariant-not-position
// @expect-error E0400 "@invariant can only be applied to @builtin(position)"
// @invariant only valid on @builtin(position)

struct Out {
    @location(0) @invariant color: vec4f,
    @builtin(position) pos: vec4f,
}

@vertex
fn main() -> Out {
    return Out();
}
