// @test: errors/io/builtin-position-wrong-type-vec4i
// @expect-error E0200 "@builtin(position) requires type 'vec4<f32>'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@vertex
fn main() -> @builtin(position) vec4<i32> {
    return vec4<i32>(0, 0, 0, 1);
}
