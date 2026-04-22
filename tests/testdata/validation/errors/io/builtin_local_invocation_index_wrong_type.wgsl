// @test: errors/io/builtin-local-invocation-index-wrong-type
// @expect-error E0200 "@builtin(local_invocation_index) requires type 'u32'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) idx : vec3<u32>) {}
