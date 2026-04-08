// @test: types/entry-point-compute
// @expect-valid
// @spec-ref: 11.1 "Entry Points"
// Compute entry point with workgroup size

struct Data {
    values : array<f32>,
}

@group(0) @binding(0) var<storage, read_write> data : Data;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id : vec3<u32>) {
    let idx = id.x;
    data.values[idx] = data.values[idx] * 2.0;
}
