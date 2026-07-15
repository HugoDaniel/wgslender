// @test: uniformity/divergent-return-barrier
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U2
// False-negative #6: an early `return` under a non-uniform condition means the
// branches do NOT reconverge (behavior != {Next}), so control flow after the
// `if` stays non-uniform and the trailing barrier is a violation. Today the
// scalar state is restored after the `if`, masking it. VALID today; INVALID
// after U2 implements the behavior/reconvergence rule.

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    if (global_invocation_id.x > 0u) {
        return;
    }
    workgroupBarrier();
}
