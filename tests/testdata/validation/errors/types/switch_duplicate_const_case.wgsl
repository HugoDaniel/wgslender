// @test: errors/types/switch-duplicate-const-case
// @expect-error E0306 "duplicate case selector"
// Const-propagated values detected as duplicate switch cases

const X: i32 = 1;

@compute @workgroup_size(1)
fn main() {
    var v: i32 = 0;
    switch v {
        case X: { v = 10; }
        case 1: { v = 20; }
        default: { v = 0; }
    }
}
