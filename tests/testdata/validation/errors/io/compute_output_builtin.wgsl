// @test: errors/io/compute-output-builtin
// @expect-error E0600 "must not return a value"
// spec-ref: §15.3 Compute Shader Entry Points

@compute @workgroup_size(1)
fn main() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.0);
}
