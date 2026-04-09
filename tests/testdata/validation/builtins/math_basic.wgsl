// @test: builtins/math-basic
// @expect-valid
// @spec-ref: 17.3 "Numeric Built-in Functions"
// Basic math builtin functions

@fragment
fn main() {
    let a = abs(-5.0);
    let b = clamp(1.5, 0.0, 1.0);
    let c = max(1.0, 2.0);
    let d = min(1.0, 2.0);
    let e = floor(1.7);
    let f = ceil(1.2);
    let g = round(1.5);
    let h = fract(1.7);
    let i = sign(-5.0);
    let j = sqrt(4.0);
    let k = pow(2.0, 3.0);
    let l = exp(1.0);
    let m = log(2.718281828);
    let n = sin(0.0);
    let o = cos(0.0);
    let p = tan(0.0);
}
