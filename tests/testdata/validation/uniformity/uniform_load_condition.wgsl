// @test: uniformity/uniform-load-condition
// @expect-valid
// @spec-ref: 15 "Uniformity"
// U2 valid twin for the storage/workgroup load reds: a load from a
// `var<uniform>` buffer is uniform per spec §15, so gating a barrier on it is
// legal. Pins that the value-uniformity dataflow classifies address spaces by
// their actual storage class (uniform => uniform) rather than tainting every
// module-var load. Must stay green once U2 lands the `values` map.

@group(0) @binding(0) var<uniform> config : vec4<u32>;

@compute @workgroup_size(64)
fn main() {
    if (config.x > 0u) {
        workgroupBarrier();
    }
}
