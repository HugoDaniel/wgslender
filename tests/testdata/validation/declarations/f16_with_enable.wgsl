// @test: declarations/f16-with-enable
// @expect-valid
// f16 types allowed when enable directive present

enable f16;

var<private> x: f16;
var<private> v: vec3<f16>;

@compute @workgroup_size(1)
fn main() {
    x = 1.0h;
    v = vec3<f16>(1.0h, 2.0h, 3.0h);
}
