// @test: errors/io/workgroup-size-on-vertex
// @expect-error E0400 "@workgroup_size is only valid on compute entry points"
// spec-ref: §11.2.3 workgroup_size

@vertex @workgroup_size(64)
fn main() -> @builtin(position) vec4<f32> {
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
