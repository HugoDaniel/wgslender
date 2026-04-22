// @test: errors/declarations/builtin-on-override
// @expect-error E0400 "@builtin is not valid on module-scope override declarations"
// spec-ref: §11.1 builtin

@builtin(front_facing) override b: bool = false;

@fragment
fn main() -> @location(0) vec4<f32> {
    return select(vec4<f32>(0.0), vec4<f32>(1.0), b);
}
