// @test: types/loop-with-break-if
// @expect-valid
// Loop with return inside — not infinite

@compute @workgroup_size(1)
fn main() {
    var i: i32 = 0;
    loop {
        i = i + 1;
        if (i >= 10) {
            return;
        }
    }
}
