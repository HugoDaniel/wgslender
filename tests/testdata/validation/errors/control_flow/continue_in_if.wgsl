// @test: errors/control-flow/continue-in-if
// @expect-error E0501 "continue"
// Continue in if but not in loop

@fragment
fn main() {
    if (true) {
        continue;  // Error: continue outside loop
    }
}
