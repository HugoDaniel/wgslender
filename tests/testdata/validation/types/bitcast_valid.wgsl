// @test: types/bitcast-valid
// @expect-valid
// Valid bitcast operations with matching bit-widths

@compute @workgroup_size(1)
fn main() {
    var x: f32 = 1.0;
    let a = bitcast<u32>(x);
    var y: u32 = 42u;
    let b = bitcast<f32>(y);
    var z: i32 = 7;
    let c = bitcast<f32>(z);
    var v2: vec2<f32> = vec2f(1.0, 2.0);
    let d = bitcast<vec2u>(v2);
}
