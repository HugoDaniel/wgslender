// @test: errors/declarations/builtin-on-module-storage-var
// @expect-error E0400 "@builtin is not valid on module-scope var declarations"
// spec-ref: §11.1 builtin — must still fire alongside valid @group/@binding

struct Data { x: vec4<f32>, }

@group(0) @binding(0) @builtin(position) var<storage, read> buf: Data;

@fragment
fn main() -> @location(0) vec4<f32> {
    return buf.x;
}
