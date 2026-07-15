// @test: uniformity/helper-barrier-uniform-call
// @expect-valid
// @spec-ref: 15 "Uniformity"
// U3 valid twin for false-negative #4: the same helper containing an
// unconditional barrier, but called from uniform control flow. The callee
// summary records a `call_site_requirement`, yet the call site's control flow
// is uniform, so no violation is reported. Pins that summaries taint call sites
// only under non-uniform CF (never manufacture a false positive from a uniform
// caller).

fn sync() {
    workgroupBarrier();
}

@compute @workgroup_size(64)
fn main() {
    sync();
}
