// @test: declarations/const-assert-valid
// @expect-valid
// @spec-ref: 9.7 "Const Assert Statement"
// Valid const_assert declarations with boolean expressions.

const_assert true;
const_assert 1 == 1;
const_assert 2 > 1;
const_assert !(false);

@fragment
fn main() {
    const_assert true;
    const_assert 1 < 2;
}
