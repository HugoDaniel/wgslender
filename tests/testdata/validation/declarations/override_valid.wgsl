// @test: declarations/override-valid
// @expect-valid
// @spec-ref: 6.2.2 "Override Declarations"
// Valid override declarations with @id attributes in valid range.

@id(0) override x : f32 = 1.0;
@id(1) override y : i32 = 0;
@id(65535) override z : u32 = 42u;
override w : bool = true;

@compute @workgroup_size(1)
fn main() {
}
