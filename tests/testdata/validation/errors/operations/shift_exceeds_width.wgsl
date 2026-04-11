// @test: errors/operations/shift-exceeds-width
// @expect-error E0201 "exceeds bit width"
// Shift amount must be less than bit width of operand

@compute @workgroup_size(1)
fn main() {
    let x: u32 = 5u;
    let y = x << 33u;
}
