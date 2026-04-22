// @test: types/entry-point-compute-all-builtins
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs

@group(0) @binding(0) var<storage, read_write> sink : vec3<u32>;

@compute @workgroup_size(1)
fn main(
    @builtin(local_invocation_id) lid : vec3<u32>,
    @builtin(local_invocation_index) lidx : u32,
    @builtin(global_invocation_id) gid : vec3<u32>,
    @builtin(workgroup_id) wid : vec3<u32>,
    @builtin(num_workgroups) nwg : vec3<u32>,
) {
    sink = lid + gid + wid + nwg + vec3<u32>(lidx);
}
