// @test: uniformity/barrier-uniform
// @expect-valid
// @spec-ref: 15 "Uniformity"
// Barrier calls in uniform control flow

@group(0) @binding(0) var<storage, read_write> data : array<f32>;

var<workgroup> shared_data : array<f32, 64>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_id) lid : vec3<u32>) {
    let idx = lid.x;

    // Load into shared memory
    shared_data[idx] = data[idx];

    // Barrier in uniform control flow
    workgroupBarrier();

    // Use shared memory
    data[idx] = shared_data[63u - idx];
}
