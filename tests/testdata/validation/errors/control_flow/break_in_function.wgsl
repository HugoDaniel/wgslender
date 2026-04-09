// @test: errors/control-flow/break-in-function
// @expect-error E0500 "break"
// Break in function but not in loop

fn helper() {
    break;  // Error: break outside loop
}

@fragment
fn main() {
    for (var i = 0; i < 10; i = i + 1) {
        helper();
    }
}
