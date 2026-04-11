// @test: errors/declarations/diagnostic-invalid-severity
// @expect-error E0903 "invalid diagnostic severity"
// Invalid diagnostic severity 'banana'

diagnostic(banana, derivative_uniformity);

@compute @workgroup_size(1)
fn main() {}
