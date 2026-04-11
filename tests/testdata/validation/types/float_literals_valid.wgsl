// @test: types/float-literals-valid
// @expect-valid
// Various valid float literal formats

enable f16;

@compute @workgroup_size(1)
fn main() {
    let a = 1.0;
    let b = 0.0;
    let c = 3.14;
    let d = 1e10;
    let e = 1.0f;
    let f = 0.5f;
    let g = 1.0h;
    let h = 0.001;
    let i = 1e-5;
    let j = -0.0;
}
