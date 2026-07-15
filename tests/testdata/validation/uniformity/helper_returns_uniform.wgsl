// @test: uniformity/helper-returns-uniform
// @expect-valid
// @spec-ref: 15 "Uniformity"
// U3 value-side red (false-positive removal): a helper whose return ignores its
// argument (`ret = uniform`, arg-independent) is uniform *even when called with
// a non-uniform argument*, so gating a barrier on its result is legal. This is a
// false positive under U2's coarse "result is non-uniform iff any argument is"
// rule, which taints from the non-uniform arg regardless of whether the return
// uses it. U3's precise `depends_on_args` summary (empty here) folds to uniform.
// Pins that summaries lean false-negative per §2.1 — the callee's actual return
// dependence, not its argument list, decides.

fn getconst(v : u32) -> u32 {
    return 42u;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let idx = getconst(gid.x);
    if (idx > 0u) {
        workgroupBarrier();
    }
}
