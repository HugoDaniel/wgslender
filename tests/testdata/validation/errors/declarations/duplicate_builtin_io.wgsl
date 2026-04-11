// @test: errors/declarations/duplicate-builtin-io
// @expect-error E0602 "duplicate @builtin"
// Two struct members with same @builtin is invalid

struct Out {
    @builtin(position) a: vec4f,
    @builtin(position) b: vec4f,
}

@vertex
fn main() -> Out {
    return Out();
}
