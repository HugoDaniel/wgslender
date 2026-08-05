// Parses, does not type-check: `scale` is never declared. Embedding this is a
// compile error, which is what the `compile_fail` example demonstrates.

@compute @workgroup_size(1)
fn main() {
    let doubled = scale * 2.0;
}
