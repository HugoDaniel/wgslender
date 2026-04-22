// @test: errors/declarations/location-on-override
// @expect-error E0400 "@location is not valid on module-scope override declarations"
// spec-ref: §11.2 location

@location(0) override o: f32 = 0.0;

@fragment
fn main() -> @location(0) vec4<f32> {
    return vec4<f32>(o);
}
