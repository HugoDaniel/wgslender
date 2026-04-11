// @test: errors/calls/must-use-ignored
// @expect-error E0212 "must be used"
// Builtin return value discarded as statement

@compute @workgroup_size(1)
fn main() {
    abs(1.0);
}
