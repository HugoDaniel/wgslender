// @test: errors/io/location-negative
// @expect-error E0404 "@location value must be non-negative"
// spec-ref: §11.1 location

@fragment
fn main(@location(-1) x : vec4<f32>) -> @location(0) vec4<f32> {
    return x;
}
