// @test: errors/declarations/const-assert-non-bool
// @expect-error E0302 "must be 'bool'"
// Spec: const_assert expression must be of type bool.

const_assert 42;

@fragment
fn main() {
}
