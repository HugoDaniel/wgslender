// @test: errors/io/workgroup-size-on-fragment
// @expect-error E0400 "@workgroup_size is only valid on compute entry points"
// spec-ref: §11.2.3 workgroup_size

@fragment @workgroup_size(32)
fn main() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0);
}
