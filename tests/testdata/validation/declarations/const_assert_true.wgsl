// @test: declarations/const-assert-true
// @expect-valid
// const_assert with true conditions

const N = 4;
const_assert(N > 0);
const_assert(N == 4);
const_assert(true);

@compute @workgroup_size(1)
fn main() {}
