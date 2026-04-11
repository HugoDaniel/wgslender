// @test: errors/declarations/unknown-enable-feature
// @expect-error E0901 "unknown enable feature"
// Enable directive with nonexistent feature name

enable nonexistent_feature;

@compute @workgroup_size(1)
fn main() {}
