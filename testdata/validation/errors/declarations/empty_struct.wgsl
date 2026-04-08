// @test: errors/declarations/empty-struct
// @expect-error E0310 "at least one member"
// Spec: struct must have at least 1 member.

struct Empty {}

@fragment
fn main() {
}
