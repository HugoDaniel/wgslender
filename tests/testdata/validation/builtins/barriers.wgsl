// @test: builtins/barriers
// @expect-valid
// @spec-ref: 17.11 "Synchronization Built-in Functions"
// All three barriers exercised in a uniform-control-flow context.

var<workgroup> shared_data : array<f32, 64>;

@compute @workgroup_size(64)
fn main() {
    workgroupBarrier();
    storageBarrier();
    textureBarrier();
}
