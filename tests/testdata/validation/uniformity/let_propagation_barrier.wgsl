// @test: uniformity/let-propagation-barrier
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U2
// False-negative #2: the non-uniform builtin value flows through a `let` before
// reaching the condition, so no identifier in the condition matches a builtin
// name. Needs value-uniformity dataflow (`values` map) to track the taint across
// the binding. VALID today; INVALID after U2.

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    let idx = global_invocation_id.x;
    if (idx > 0u) {
        workgroupBarrier();
    }
}
