// @test: uniformity/barrier-after-balanced-if
// @expect-valid
// @spec-ref: 15 "Uniformity"
// A barrier AFTER an `if` whose branches both fall through (behavior == {Next})
// is uniform: control flow reconverges past the `if`, so the barrier runs in
// uniform flow even though the condition is non-uniform. Pins the reconvergence
// rule U2 must preserve — valid today (state is restored after the `if`), and
// must stay valid once dataflow makes the condition genuinely non-uniform.

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    if (global_invocation_id.x > 0u) {
        let x = 1.0;
    } else {
        let y = 2.0;
    }
    workgroupBarrier();
}
