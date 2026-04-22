// @test: errors/io/builtin-local-invocation-id-wrong-type
// @expect-error E0200 "@builtin(local_invocation_id) requires type 'vec3<u32>'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_id) id : vec2<u32>) {
    let _ = id;
}
