// @test: types/nesting-deep-valid
// @expect-valid
// Deep but valid nesting (well under 127 limit)

@compute @workgroup_size(1)
fn main() {
    var x: i32 = 0;
    if (true) {
        if (true) {
            for (var i: i32 = 0; i < 10; i++) {
                if (true) {
                    var j: i32 = 0;
                    while (j < 5) {
                        if (true) {
                            loop {
                                if (true) {
                                    if (true) {
                                        x = x + 1;
                                        break;
                                    }
                                }
                                break;
                            }
                        }
                        j = j + 1;
                    }
                }
            }
        }
    }
}
