// Calling a barrier with arguments — must be rejected. The arity check in
// `Builtin.checkArgCount` fires before overload resolution, so this trips
// E0202 (invalid arg count) rather than the overload-resolution E0203.
// @expect-error E0202

@compute @workgroup_size(1)
fn main() {
    workgroupBarrier(1u);
}
