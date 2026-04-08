// @test: errors/declarations/recursive-struct
// @expect-error E0104 "recursively"
// Spec: struct must not directly or indirectly contain itself.

struct Node {
    value : f32,
    next : Node,
}

@fragment
fn main() {
}
