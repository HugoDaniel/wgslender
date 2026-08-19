// @test: errors/calls/member-callee
// @expect-error E0204 "not callable"
// A member access applied like a function. WGSL has no method calls, so this
// is `not_callable` — it used to reach `lookupType` with an EMPTY name and
// trip its assert (pngine's corpus mutation sweep produced it from a single
// flipped byte: `.vel = vec2f(` → `.vel ( vec2f(`).

struct S { v: f32 }

@compute @workgroup_size(1)
fn main() {
    var s: S;
    s.v(1.0);
}
