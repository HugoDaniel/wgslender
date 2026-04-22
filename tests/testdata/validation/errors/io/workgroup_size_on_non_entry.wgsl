// @test: errors/io/workgroup-size-on-non-entry
// @expect-error E0400 "@workgroup_size is only valid on compute entry points"
// spec-ref: §11.2.3 workgroup_size

@workgroup_size(64)
fn helper() -> f32 { return 0.0; }

@compute @workgroup_size(1)
fn main() {
    let _ = helper();
}
