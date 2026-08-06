// Type-checks and stays valid, but trips two warning-severity diagnostics: a
// redundant cast and a statement that can never run. Under -strict both become
// errors and the generator refuses it.

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    let doubled = u32(i * 2u);
    counters[i] = doubled;
    return;
    counters[i] = 0u;
}
