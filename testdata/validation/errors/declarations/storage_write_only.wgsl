// @test: errors/declarations/storage-write-only
// @expect-error E0305 "access mode"
// Storage var access mode must be 'read' or 'read_write', not 'write'

struct Data {
    value : f32,
}

@group(0) @binding(0) var<storage, write> buf : Data;  // Error: invalid access mode

@compute @workgroup_size(1)
fn main() {
}
