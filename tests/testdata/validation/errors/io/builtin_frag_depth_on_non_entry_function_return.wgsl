// @test: errors/io/builtin-frag-depth-on-non-entry-function-return
// @expect-error E0400 "@builtin is only valid on entry point function return types"
// spec-ref: §11.1 builtin

fn helper() -> @builtin(frag_depth) f32 {
    return 0.5;
}

@fragment
fn main() -> @builtin(frag_depth) f32 {
    return helper();
}
