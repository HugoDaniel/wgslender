// @test: uniformity/helper-barrier-non-uniform-call
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U3
// False-negative #4 (callee side): a helper containing an unconditional barrier,
// called from inside non-uniform control flow, is a violation reported at the
// call site. Needs bottom-up call summaries (call_site_requirement). Today user
// calls aren't looked up at all. VALID today; INVALID after U3.

fn sync() {
    workgroupBarrier();
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    if (global_invocation_id.x > 0u) {
        sync();
    }
}
