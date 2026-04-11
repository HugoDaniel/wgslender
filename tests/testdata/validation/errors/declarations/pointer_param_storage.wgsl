// @test: errors/declarations/pointer-param-storage
// @expect-error E0304 "must use 'function' or 'private'"
// Pointer param with storage address space not allowed by default

fn update(p: ptr<storage, f32>) {
    *p = 1.0;
}

@compute @workgroup_size(1)
fn main() {}
