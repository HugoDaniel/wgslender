// @test: builtins/must-use-consumed
// @expect-valid
// @must_use builtins with results properly consumed

@compute @workgroup_size(1)
fn main() {
    let a = abs(-5.0);
    let b = sin(a);
    let c = max(a, b);
    let d = clamp(c, 0.0, 1.0);
    let v = vec3f(1.0, 2.0, 3.0);
    let e = dot(v, v);
    let f = length(v);
    let g = normalize(v);
    let h = floor(d);
    let i = ceil(d);
    let j = min(a, b);
}
