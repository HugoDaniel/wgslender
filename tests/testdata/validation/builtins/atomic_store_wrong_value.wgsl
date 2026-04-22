// atomicStore with float value into u32 atomic — must be rejected.
// @expect-error E0203 "no matching overload for 'atomicStore'"

struct C { c : atomic<u32>, }
@group(0) @binding(0) var<storage, read_write> s : C;

@compute @workgroup_size(1)
fn main() {
    atomicStore(&s.c, 1.0);
}
