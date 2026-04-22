// @test: errors/io/invariant-on-direct-return-non-position
// @expect-error E0400 "@invariant can only be applied to @builtin(position)"
// spec-ref: §11.3 invariant

@fragment
fn main() -> @builtin(frag_depth) @invariant f32 {
    return 0.5;
}
