// @test: errors/io/builtin-global-invocation-id-wrong-element
// @expect-error E0200 "@builtin(global_invocation_id) requires type 'vec3<u32>'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id : vec3<i32>) {
    let _ = id;
}
