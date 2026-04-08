// @test: builtins/vector-math
// @expect-valid
// @spec-ref: 17.3 "Numeric Built-in Functions"
// Vector math operations

@fragment
fn main() {
    let v1 = vec3<f32>(1.0, 0.0, 0.0);
    let v2 = vec3<f32>(0.0, 1.0, 0.0);

    let d = dot(v1, v2);
    let c = cross(v1, v2);
    let n = normalize(v1);
    let l = length(v1);
    let dist = distance(v1, v2);
    let r = reflect(v1, v2);
    let m = mix(v1, v2, 0.5);
    let s = step(vec3<f32>(0.5), v1);
    let sm = smoothstep(vec3<f32>(0.0), vec3<f32>(1.0), v1);
}
