// @test: uniformity/renamed-param-barrier
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U1
// False-negative #1: the builtin param is renamed (`gid`, not the magic string
// `global_invocation_id`), so today's name-matching analyzer never taints the
// condition and misses the barrier violation. VALID today; must become INVALID
// once sources are grounded in the parameter's SymbolIndex (U1).

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    if (gid.x > 0u) {
        workgroupBarrier();
    }
}
