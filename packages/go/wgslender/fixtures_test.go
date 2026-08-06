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
