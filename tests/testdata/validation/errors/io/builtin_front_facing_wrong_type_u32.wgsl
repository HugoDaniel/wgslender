// @test: errors/io/builtin-front-facing-wrong-type-u32
// @expect-error E0200 "@builtin(front_facing) requires type 'bool'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@fragment
fn main(@builtin(front_facing) f : u32) -> @location(0) vec4<f32> {
    return vec4<f32>(f32(f), 0.0, 0.0, 1.0);
}
