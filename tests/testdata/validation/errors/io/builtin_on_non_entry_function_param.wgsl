// @test: errors/io/builtin-on-non-entry-function-param
// @expect-error E0400 "@builtin is only valid on entry point function parameters"
// spec-ref: §11.1 builtin

fn helper(@builtin(vertex_index) idx : u32) -> u32 {
    return idx;
}

@vertex
fn main() -> @builtin(position) vec4<f32> {
    let _ = helper(0u);
    return vec4<f32>(0.0);
}
