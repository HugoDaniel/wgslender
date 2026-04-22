// @test: errors/io/location-on-non-entry-function-return
// @expect-error E0400 "@location is only valid on entry point function return types"
// spec-ref: §11.2 location

fn helper() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0);
}

@fragment
fn main() -> @location(0) vec4<f32> {
    return helper();
}
