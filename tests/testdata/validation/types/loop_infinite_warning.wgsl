// @test: types/loop-infinite-warning
// @expect-valid
// Infinite loop is a warning, not error — shader is still valid

@compute @workgroup_size(1)
fn main() {
    loop {
        var x: i32 = 1;
    }
}
