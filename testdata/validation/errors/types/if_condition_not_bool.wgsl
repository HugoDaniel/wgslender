// @test: errors/types/if-condition-not-bool
// @expect-error E0200 "must be bool"
// If condition must be bool type

@fragment
fn main() {
    if (1.23) {  // Error: condition must be bool, got f32
    }
}
