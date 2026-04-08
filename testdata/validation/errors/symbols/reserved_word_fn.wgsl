// @test: errors/symbols/reserved-word-fn
// @expect-error E0004 "reserved word"
// Reserved word used as function name

fn class() -> f32 {
    return 1.0;
}

@fragment
fn main() -> @location(0) vec4f {
    return vec4f(1.0);
}
