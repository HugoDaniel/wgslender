// @test: errors/declarations/builtin-on-module-private-var
// @expect-error E0400 "@builtin is not valid on module-scope var declarations"
// spec-ref: §11.1 builtin

@builtin(position) var<private> p: vec4<f32>;

@vertex
fn main() -> @builtin(position) vec4<f32> {
    return p;
}
