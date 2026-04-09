// @test: errors/types/for-condition-not-bool
// @expect-error E0200 "must be bool"
// For loop condition must be bool type

@fragment
fn main() {
    for (var i = 0; i; i = i + 1) {  // Error: condition must be bool, got i32
    }
}
