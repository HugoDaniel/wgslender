package wgslender_test

// Shaders shared by the tests in this package, mirroring the fixture set the
// Rust package pins its own behaviour against (packages/rust/wgslender-core/
// tests/fixtures) so the two bindings can be compared row for row.
//
// They are embedded rather than read at run time: a fixture that goes missing
// then fails the build with its own name in the message, instead of failing
// every table that used it with an I/O error.

import _ "embed"

// demoWGSL exercises the four binding kinds, a struct, a helper function and
// one compute entry point.
//
//go:embed testdata/demo.wgsl
var demoWGSL string

// renderWGSL is a vertex/fragment pair, so neither entry point has a workgroup
// size.
//
//go:embed testdata/render.wgsl
var renderWGSL string

// invalidWGSL parses but does not type-check: undeclared_variable is never
// declared.
//
//go:embed testdata/invalid.wgsl
var invalidWGSL string

// warningWGSL is valid and trips two warning-severity diagnostics.
//
//go:embed testdata/warning.wgsl
var warningWGSL string

// unparseableWGSL is not WGSL at all — the parser gives up on it, which is the
// only input class that makes minification a no-op.
const unparseableWGSL = "fn main( { let ; }"

// layoutWGSL is the npm suite's own reflection shader (packages/js-npm/test/
// _suite.cjs), kept here verbatim because the layout number it pins — 24 bytes
// — belongs to *this* struct and not to demoWGSL's Params, which lays out to
// 16. Reflection numbers are only meaningful next to the source that produced
// them, so the two live in different fixtures on purpose.
const layoutWGSL = `struct Inputs {
    time: f32,
    resolution: vec2<u32>,
    brightness: f32,
}

@group(0) @binding(0) var<uniform> inputs: Inputs;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let t = inputs.time * inputs.brightness;
    _ = t;
    _ = id;
}
`

// overridesWGSL carries everything demoWGSL and renderWGSL between them do not:
// pipeline-overridable constants with and without an @id, a type alias, a
// storage texture (whose TypeInfo names a format as a *string* where every
// other kind names one as a nested TypeInfo), a fixed-size array, and a
// workgroup size that depends on an override.
const overridesWGSL = `override grid: u32 = 8u;
@id(42) override scale: f32 = 1.5;
alias Index = u32;

@group(0) @binding(0) var out_tex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(1) var<storage, read> idx: array<Index, 4>;

@compute @workgroup_size(grid)
fn main(@builtin(global_invocation_id) id: vec3u) {
    textureStore(out_tex, id.xy, vec4f(scale * f32(idx[0])));
}
`

// holesWGSL leaves gaps in the bind-group grid: group 0 has bindings 0 and 2
// but no 1, and group 2 exists while group 1 does not. Anything that models
// bind groups as dense arrays gets this wrong.
const holesWGSL = `@group(0) @binding(0) var<uniform> a: f32;
@group(0) @binding(2) var<uniform> b: f32;
@group(2) @binding(5) var<uniform> c: f32;

@compute @workgroup_size(1)
fn main() {
    _ = a;
    _ = b;
    _ = c;
}
`

// unusedWGSL is valid and warning-free, but declares a helper nothing ever
// calls, so no-unused-vars has something to find.
const unusedWGSL = `@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

fn unused_helper(x: f32) -> f32 {
    return x * 2.0;
}

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
`

// unusedWithDirectiveWGSL is unusedWGSL with a file-level comment switching
// no-unused-vars off.
const unusedWithDirectiveWGSL = `// wgslender-disable no-unused-vars

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

fn unused_helper(x: f32) -> f32 {
    return x * 2.0;
}

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
`

// deadDirectiveWGSL is clean, but carries a directive for a rule that never
// fires — exactly what ReportUnusedDisableDirectives exists to surface.
const deadDirectiveWGSL = `// wgslender-disable no-self-assign

@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    counters[i] = i;
}
`
