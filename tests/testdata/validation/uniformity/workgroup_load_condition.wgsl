// @test: uniformity/workgroup-load-condition
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U2
// False-negative #3 (workgroup): a load from `var<workgroup>` is non-uniform
// per spec §15 (except via workgroupUniformLoad). Gating a barrier on it is a
// violation the current analyzer never sees. VALID today; INVALID after U2.

var<workgroup> tile : array<u32, 64>;

@compute @workgroup_size(64)
fn main() {
    if (tile[0] > 0u) {
        workgroupBarrier();
    }
}
