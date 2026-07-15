// @test: uniformity/barrier-non-uniform-if
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// A barrier called inside control flow gated on a non-uniform builtin input is
// a violation. This is the canonical firing case and stays an error through the
// whole track (magic literal param name today; symbol-grounded after U1).

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    if (global_invocation_id.x > 0u) {
        workgroupBarrier();
    }
}
