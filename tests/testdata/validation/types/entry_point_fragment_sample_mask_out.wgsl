// @test: types/entry-point-fragment-sample-mask-out
// @expect-valid
// @spec-ref: §9.3.1 Built-in Inputs and Outputs

@fragment
fn main() -> @builtin(sample_mask) u32 {
    return 0xffffffffu;
}
