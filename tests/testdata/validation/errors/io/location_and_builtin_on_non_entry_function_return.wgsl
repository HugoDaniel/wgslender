// @test: errors/io/location-and-builtin-on-non-entry-function-return
// @expect-error E0400 "@location is only valid on entry point function return types"
// @expect-error E0400 "@builtin is only valid on entry point function return types"
// spec-ref: §11.1, §11.2

fn helper() -> @location(0) @builtin(position) vec4<f32> {
    return vec4<f32>(0.0);
}

@vertex
fn main() -> @builtin(position) vec4<f32> {
    return helper();
}
