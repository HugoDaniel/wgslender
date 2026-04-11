// @test: errors/calls/must-use-max
// @expect-error E0212 "must be used"
// max() return value discarded

@compute @workgroup_size(1)
fn main() {
    max(1.0, 2.0);
}
