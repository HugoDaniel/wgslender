// @test: errors/declarations/const-assert-false
// @expect-error E0807 "condition is false"
// const_assert that evaluates to false

const_assert(1 == 2);

@compute @workgroup_size(1)
fn main() {}
