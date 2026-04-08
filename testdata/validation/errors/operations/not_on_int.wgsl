// @test: errors/operations/not-on-int
// @expect-error E0201 "logical not"
// Logical not only valid on bool

@fragment
fn main() {
    let x = !42;  // Error: logical not not valid for i32
}
