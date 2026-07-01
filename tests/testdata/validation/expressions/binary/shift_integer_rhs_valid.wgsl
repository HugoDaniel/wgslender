// @test: expressions/binary/shift-integer-rhs-valid
// @expect-valid
// Shift operations with valid RHS: u32 literal/var, abstract-int literal,
// in-range constants, both << and >> variants, and component-wise vector shifts.

@compute @workgroup_size(1)
fn main() {
    let a: u32 = 7u;
    let b: u32 = 2u;
    let _sl_uu = a << b;        // u32 << u32
    let _sr_uu = a >> b;        // u32 >> u32
    let _sl_ua = a << 2u;       // u32 << u32 literal
    let _sl_ai = a << 1;        // u32 << abstract-int
    let _sl_ii = 1i << 2u;      // i32 << u32
    let _sl_aa = 1 << 2;        // abstract-int << abstract-int
    let _sl_z  = a << 0u;       // shift by zero
    let _sl_31 = 1u << 31u;     // max in-range for u32

    // Component-wise vector shifts: vecN<int> shifted by vecN<u32> (WGSL §8.7).
    let vu = vec2u(1u, 2u);
    let vi = vec3i(1i, 2i, 3i);
    let _sv_uu = vu >> vec2u(1u, 0u);   // vec2<u32> >> vec2<u32>
    let _sv_iu = vi << vec3u(1u, 2u, 3u); // vec3<i32> << vec3<u32>
}
