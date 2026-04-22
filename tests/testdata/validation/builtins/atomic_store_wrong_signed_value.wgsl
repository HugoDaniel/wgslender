// atomicStore on atomic<i32> with a u32 value — different scalar kinds
// must not bind to the same `bound_scalar` slot.
// @expect-error E0203

struct C { c : atomic<i32>, }
@group(0) @binding(0) var<storage, read_write> s : C;

@compute @workgroup_size(1)
fn main() {
    atomicStore(&s.c, 1u);
}
