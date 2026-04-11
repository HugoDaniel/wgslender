// @test: errors/declarations/float-literal-overflow
// @expect-error E0314 "infinity"
// Float literal overflows to infinity

@compute @workgroup_size(1)
fn main() {
    let x = 1e999f;
}
