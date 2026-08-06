// Valid, but sloppy in two ways the validator reports at warning severity.
// Under `{ strict: true }` both are promoted to errors — which is the whole
// point of this fixture, and what validate.mts demonstrates.
//
// (The plan for this example originally used a non-uniform workgroupBarrier
// here. That is an *error*, E0701, not a warning — so it could not show a
// promotion. The oracle said so; the fixture changed.)

@group(0) @binding(0) var<storage, read_write> buf: array<u32>;

fn scale(v: u32) -> u32 {
  let doubled = v * 2u;
  return doubled;
  let unused = doubled + 1u;  // W0103: code is unreachable
}

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
  let n: u32 = scale(i);
  buf[i] = u32(n);              // W0101: redundant cast, n is already u32
}
