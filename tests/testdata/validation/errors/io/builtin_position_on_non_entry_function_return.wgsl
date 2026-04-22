// @test: errors/io/builtin-position-on-non-entry-function-return
// @expect-error E0400 "@builtin is only valid on entry point function return types"
// spec-ref: §11.1 builtin

fn helper() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}

@vertex
fn main() -> @builtin(position) vec4<f32> {
    return helper();
}
