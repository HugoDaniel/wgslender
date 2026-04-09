// @test: declarations/atomic-valid
// @expect-valid
// @spec-ref: 5.2 "Atomic Types"
// Valid atomic types: only i32 and u32 are allowed.

var<workgroup> counter_i : atomic<i32>;
var<workgroup> counter_u : atomic<u32>;

@compute @workgroup_size(1)
fn main() {
    atomicStore(&counter_i, 0);
    atomicStore(&counter_u, 0u);
}
