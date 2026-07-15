// @test: uniformity/helper-returns-non-uniform
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U3
// False-negative #5 (value side): a helper returns a value derived from its
// argument; called with a non-uniform builtin, its result is non-uniform and
// gating a barrier on it is a violation. Needs the summary's `ret` uniformity
// (depends_on_args). Today callers see the result as uniform. VALID today;
// INVALID after U3.

fn getidx(v : vec3<u32>) -> u32 {
    return v.x;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    let idx = getidx(global_invocation_id);
    if (idx > 0u) {
        workgroupBarrier();
    }
}
