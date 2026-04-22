// @test: errors/io/builtin-frag-depth-wrong-type-f16
// @expect-error E0200 "@builtin(frag_depth) requires type 'f32'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

enable f16;

@fragment
fn main() -> @builtin(frag_depth) f16 {
    return 0.5h;
}
