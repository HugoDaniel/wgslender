// @test: errors/control_flow/break-if-not-last
// @expect-error E0500 "must be the last statement"
// break if must be the last statement in a continuing block

@compute @workgroup_size(1)
fn main() {
    var i = 0;
    loop {
        if (i >= 10) { break; }
        continuing {
            break if i > 5;
            i = i + 1;
        }
    }
}
