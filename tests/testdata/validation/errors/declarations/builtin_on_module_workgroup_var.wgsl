// @test: errors/declarations/builtin-on-module-workgroup-var
// @expect-error E0400 "@builtin is not valid on module-scope var declarations"
// spec-ref: §11.1 builtin

@builtin(local_invocation_index) var<workgroup> idx: u32;

@compute @workgroup_size(1)
fn main() {
    idx = 0u;
}
