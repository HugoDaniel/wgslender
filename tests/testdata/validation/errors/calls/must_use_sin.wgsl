// @test: errors/calls/must-use-sin
// @expect-error E0212 "must be used"
// sin() return value discarded

@compute @workgroup_size(1)
fn main() {
    sin(1.0);
}
