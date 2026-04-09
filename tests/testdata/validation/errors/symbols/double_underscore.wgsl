// @test: errors/symbols/double-underscore
// @expect-error E0004 "__"
// Double underscore prefix in identifier

@fragment
fn main() -> @location(0) vec4f {
    var __x = 5;
    return vec4f(1.0);
}
