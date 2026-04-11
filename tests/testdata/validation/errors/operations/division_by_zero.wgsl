// @test: errors/operations/division-by-zero
// @expect-error E0316 "division by zero"
// Const-expression division by zero

@compute @workgroup_size(1)
fn main() {
    let x = 10 / 0;
}
