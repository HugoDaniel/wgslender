// Valid, but trips a warning: the statement after `return` can never run.
// Only `strict = true` turns that into a compile error, which is what the
// strictness UI golden is for.

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
    return;
    counters[i] = 0u;
}
