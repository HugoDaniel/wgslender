// @test: errors/declarations/location-and-builtin
// @expect-error E0401 "cannot have both @location and @builtin"
// Same member cannot have both @location and @builtin

struct Out {
    @location(0) @builtin(position) pos: vec4f,
}

@vertex
fn main() -> Out {
    return Out();
}
