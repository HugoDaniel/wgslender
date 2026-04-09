// @test: builtins/atomic-ops
// @expect-valid
// @spec-ref: 17.7 "Atomic Built-in Functions"
// Atomic operations

struct Counter {
    count : atomic<u32>,
}

@group(0) @binding(0) var<storage, read_write> counter : Counter;

@compute @workgroup_size(64)
fn main() {
    let old = atomicAdd(&counter.count, 1u);
    let curr = atomicLoad(&counter.count);
}
