// @test: declarations/diagnostic-valid
// @expect-valid
// Valid diagnostic directive

diagnostic(off, derivative_uniformity);

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
