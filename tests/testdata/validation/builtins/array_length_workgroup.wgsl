// arrayLength on a workgroup array — must be rejected (only storage AS
// per §17.14).
// @expect-error E0203 "no matching overload for 'arrayLength'"

var<workgroup> wg : array<f32, 64>;

@compute @workgroup_size(1)
fn main() {
    let n = arrayLength(&wg);
}
