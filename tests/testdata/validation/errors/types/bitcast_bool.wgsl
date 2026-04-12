// @test: errors/types/bitcast-bool
// @expect-error E0209 "cannot bitcast from"
// bitcast operands must be numeric, not bool

@compute @workgroup_size(1)
fn main() {
    let x: bool = true;
    let y = bitcast<u32>(x);
}
