// @test: types/division-valid
// @expect-valid
// Valid division and modulo operations

@compute @workgroup_size(1)
fn main() {
    let a = 10 / 2;
    let b = 10 % 3;
    let c = 7.0 / 2.0;
    let d = 100 / 10;
    let e = 15 % 4;
}
