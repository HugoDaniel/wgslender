// @test: errors/operations/index-non-indexable
// @expect-error E0205 "not indexable"
// Indexing only valid on arrays, vectors, and matrices

@fragment
fn main() {
    let x = 1.0;
    let y = x[0];  // Error: f32 is not indexable
}
