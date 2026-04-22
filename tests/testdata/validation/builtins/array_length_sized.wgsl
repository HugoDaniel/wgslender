// arrayLength on a fixed-size array — must be rejected (only runtime-sized
// arrays are valid per §17.14).
// @expect-error E0203 "no matching overload for 'arrayLength'"

@group(0) @binding(0) var<storage, read> data : array<f32, 16>;

@compute @workgroup_size(1)
fn main() {
    let n = arrayLength(&data);
}
