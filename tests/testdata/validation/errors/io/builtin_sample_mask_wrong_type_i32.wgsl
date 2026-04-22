// @test: errors/io/builtin-sample-mask-wrong-type-i32
// @expect-error E0200 "@builtin(sample_mask) requires type 'u32'"
// spec-ref: §9.3.1 Built-in Inputs and Outputs

@fragment
fn main() -> @builtin(sample_mask) i32 {
    return 0;
}
