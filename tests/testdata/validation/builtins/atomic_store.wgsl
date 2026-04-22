// @test: builtins/atomic-store
// @expect-valid
// @spec-ref: 17.9 "Atomic Built-in Functions"
// atomicStore via declarative overload (Phase 3e migration target).

struct Counter {
    c_i : atomic<i32>,
    c_u : atomic<u32>,
}

@group(0) @binding(0) var<storage, read_write> counter : Counter;
var<workgroup> wg_i : atomic<i32>;
var<workgroup> wg_u : atomic<u32>;

@compute @workgroup_size(64)
fn main() {
    atomicStore(&counter.c_i, 0);
    atomicStore(&counter.c_i, -7i);
    atomicStore(&counter.c_u, 42u);
    atomicStore(&wg_i, 1);
    atomicStore(&wg_u, 2u);
}
