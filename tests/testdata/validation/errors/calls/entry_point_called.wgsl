// @test: errors/calls/entry-point-called
// @expect-error E0603 "cannot be the target"
// Entry point must not be called as a function

@compute @workgroup_size(1)
fn main() {}

fn helper() { main(); }
