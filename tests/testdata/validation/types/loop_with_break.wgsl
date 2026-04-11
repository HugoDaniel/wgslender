// @test: types/loop-with-break
// @expect-valid
// Loop with conditional break — not infinite

@compute @workgroup_size(1)
fn main() {
    var i: i32 = 0;
    loop {
        if (i >= 10) {
            break;
        }
        i = i + 1;
    }
}
