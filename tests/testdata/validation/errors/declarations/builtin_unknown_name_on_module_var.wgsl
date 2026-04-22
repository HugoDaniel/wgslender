// @test: errors/declarations/builtin-unknown-name-on-module-var
// @expect-error E0400 "@builtin is not valid on module-scope var declarations"
// spec-ref: §11.1 builtin — site error must still surface even for unknown builtin name

@builtin(notarealbuiltin) var<private> p: vec4<f32>;

@vertex
fn main() -> @builtin(position) vec4<f32> {
    return p;
}
