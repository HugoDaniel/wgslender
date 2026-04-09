// @test: errors/control-flow/continue-outside-loop
// @expect-error E0501 "continue"
// Continue statement must be inside a loop

@fragment
fn main() {
    continue;  // Error: continue outside loop
}
