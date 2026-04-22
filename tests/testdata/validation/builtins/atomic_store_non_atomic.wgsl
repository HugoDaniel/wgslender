// atomicStore on a non-atomic pointer — must be rejected.
// @expect-error E0203 "no matching overload for 'atomicStore'"

@group(0) @binding(0) var<storage, read_write> s : u32;

@compute @workgroup_size(1)
fn main() {
    atomicStore(&s, 1u);
}
