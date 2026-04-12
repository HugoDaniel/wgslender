// @test: errors/types/bitcast-size-mismatch
// @expect-error E0209 "bit-width"
// bitcast source and destination must have the same bit-width

@compute @workgroup_size(1)
fn main() {
    var x: f32 = 1.0;
    let y = bitcast<vec2f>(x);
}
