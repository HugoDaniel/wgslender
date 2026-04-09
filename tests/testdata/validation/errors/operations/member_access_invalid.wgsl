// @test: errors/operations/member-access-invalid
// @expect-error E0206 "no member"
// Member access on type without that member

struct S {
    a : i32,
}

@fragment
fn main() {
    var s : S;
    let x = s.b;  // Error: S has no member 'b'
}
