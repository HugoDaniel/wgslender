// @test: errors/types/while-condition-not-bool
// @expect-error E0200 "must be bool"
// While condition must be bool type

@fragment
fn main() {
    while (1) {  // Error: condition must be bool, got i32
    }
}
