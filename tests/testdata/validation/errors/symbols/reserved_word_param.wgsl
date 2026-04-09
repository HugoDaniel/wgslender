// @test: errors/symbols/reserved-word-param
// @expect-error E0004 "reserved word"
// Reserved word used as function parameter name

fn foo(import: f32) -> f32 {
    return import;
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
