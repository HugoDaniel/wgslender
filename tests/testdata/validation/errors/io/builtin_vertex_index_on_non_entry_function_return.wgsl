// @test: errors/io/builtin-vertex-index-on-non-entry-function-return
// @expect-error E0400 "@builtin is only valid on entry point function return types"
// spec-ref: §11.1 builtin

fn helper() -> @builtin(vertex_index) u32 {
    return 0u;
}

@vertex
fn main() -> @builtin(position) vec4<f32> {
    let _ = helper();
    return vec4<f32>(0.0);
}
