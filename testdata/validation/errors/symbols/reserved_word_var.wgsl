// @test: errors/symbols/reserved-word-var
// @expect-error E0004 "reserved word"
// Reserved word used as variable name

@fragment
fn main() -> @location(0) vec4f {
    var abstract = 5;
    return vec4f(1.0);
}
