// @test: errors/io/builtin-on-helper-called-from-entry-point
// @expect-error E0400 "@builtin is only valid on entry point function return types"
// spec-ref: §11.1 builtin — reachability from a valid entry point does not excuse the site

fn used_helper() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.5);
}

@vertex
fn main() -> @builtin(position) vec4<f32> {
    return used_helper();
}
