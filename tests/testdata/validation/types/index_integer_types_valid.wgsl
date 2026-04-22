// @test: types/index-integer-types-valid
// @expect-valid
// Array and vector indices: i32, u32, abstract-int literal, expressions,
// nested, pointer path — all integer scalar shapes accepted.

var<private> a: array<f32, 8>;
var<private> m: array<array<f32, 4>, 4>;
var<private> v: vec4f;

@compute @workgroup_size(1)
fn main() {
    let i32_idx: i32 = 0;
    let u32_idx: u32 = 1u;
    let _a0 = a[0];               // abstract-int literal
    let _a1 = a[0i];              // i32 literal
    let _a2 = a[0u];              // u32 literal
    let _a3 = a[i32_idx];         // i32 variable
    let _a4 = a[u32_idx];         // u32 variable
    let _a5 = a[i32_idx + 1];     // expression (common type integer)
    let _a6 = a[u32_idx + 1u];    // expression
    let _v  = v[i32_idx];         // vector base
    let _m  = m[0][1];            // nested 2D
    let _mp = (&a)[0];            // pointer base (auto-deref)
}
