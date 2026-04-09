// @test: errors/declarations/duplicate-struct-member
// @expect-error E0101 "duplicate member"
// Spec: two struct members must not have the same name.

struct S {
    x : f32,
    x : i32,
}

@fragment
fn main() {
    var s : S;
    s.x = 1.0;
}
