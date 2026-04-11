// @test: errors/declarations/float-literal-overflow-h
// @expect-error E0314 "infinity"
// Half-float literal overflows to infinity

enable f16;

@compute @workgroup_size(1)
fn main() {
    let x = 1e999h;
}
