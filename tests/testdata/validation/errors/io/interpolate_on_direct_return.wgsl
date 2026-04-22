// @test: errors/io/interpolate-on-direct-return
// @expect-error E0405 "integer-typed @location must use @interpolate(flat)"
// spec-ref: §10.2.2 Interpolation

@vertex
fn main() -> @location(0) @interpolate(linear) vec4<u32> {
    return vec4<u32>(0);
}
