// @test: errors/operations/modulo-by-zero
// @expect-error E0316 "division by zero"
// Modulo by zero in const expression

@compute @workgroup_size(1)
fn main() {
    let x = 10 % 0;
}
