// @test: errors/control-flow/break-outside-loop
// @expect-error E0500 "break"
// Break statement must be inside a loop or switch

@fragment
fn main() {
    break;  // Error: break outside loop or switch
}
