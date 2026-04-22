// arrayLength on a pointer to a scalar — must be rejected.
// @expect-error E0203 "no matching overload for 'arrayLength'"

@group(0) @binding(0) var<storage, read> data : f32;

@compute @workgroup_size(1)
fn main() {
    let n = arrayLength(&data);
}
