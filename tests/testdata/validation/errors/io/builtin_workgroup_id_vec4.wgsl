// @test: errors/io/builtin-workgroup-id-vec4
// @expect-error E0200 "@builtin(workgroup_id) requires type 'vec3<u32>'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@compute @workgroup_size(1)
fn main(@builtin(workgroup_id) id : vec4<u32>) {
    let _ = id;
}
