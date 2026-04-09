// @test: errors/operations/logical-on-int
// @expect-error E0201
// Logical operations only valid on bool

@fragment
fn main() {
    let x = 1 && 2;  // Error: logical AND not valid for i32
}
