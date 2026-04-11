// @test: errors/operations/division-by-zero-const
// @expect-error E0316 "division by zero"
// Division by const zero detected via propagation

const ZERO = 0;

@compute @workgroup_size(1)
fn main() {
    let x = 10 / ZERO;
}
