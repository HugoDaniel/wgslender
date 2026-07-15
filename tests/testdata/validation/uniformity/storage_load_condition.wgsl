// @test: uniformity/storage-load-condition
// @expect-error E0701 "barrier"
// spec: WGSL section 15 "Uniformity" (error fixture: no @spec-ref token)
// @blocked-on: U2
// False-negative #3 (storage): a load from `var<storage, read_write>` is
// non-uniform per spec §15. Gating a barrier on it is a violation the current
// analyzer never sees (non-builtin source). VALID today; INVALID after U2.

@group(0) @binding(0) var<storage, read_write> data : array<u32>;

@compute @workgroup_size(64)
fn main() {
    if (data[0] > 0u) {
        workgroupBarrier();
    }
}
