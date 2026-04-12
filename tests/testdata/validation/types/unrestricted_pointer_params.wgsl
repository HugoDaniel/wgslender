// @test: types/unrestricted-pointer-params
// @expect-valid
// With unrestricted_pointer_parameters enabled, storage pointer params are allowed

enable unrestricted_pointer_parameters;

fn write_to_storage(p: ptr<storage, f32, read_write>) {
    *p = 42.0;
}

@compute @workgroup_size(1)
fn main() {
}
