// Package wgslender minifies, validates, lints, reflects over and compiles
// WGSL (WebGPU Shading Language) shaders.
//
// It is a pure-Go binding. The wgslender engine is written in Zig and ships
// here as a WebAssembly module embedded in the package and executed by wazero,
// so building it needs no cgo, no C toolchain, and no step beyond `go build`
// on any platform Go targets.
//
// # Initialisation
//
// There is none to do. The embedded module is compiled on first use and reused
// for the lifetime of the process: the first call pays roughly 130 ms, later
// calls do not. The npm package instead makes the caller await an explicit
// initialize(); Go's lazy initialisation makes that ceremony unnecessary.
//
// # Contexts and concurrency
//
// Every function that reaches the engine takes a [context.Context] first.
// All of them are safe to call from multiple goroutines, though calls are
// serialised: the engine is a single-threaded allocator and running two calls
// through it at once corrupts its heap.
//
// # Text
//
// WGSL is defined over UTF-8, and a Go string is only bytes, so every string
// this package is given — shader source, identifiers, type text — must be valid
// UTF-8. One that is not is refused with [ErrInvalidUTF8] rather than answered,
// because the engine would copy the stray bytes into a reply that no JSON
// decoder can read back faithfully.
//
// # Errors
//
// A shader's own problems are data, not errors. Source that does not parse,
// does not type-check or trips a lint rule is reported in the result — as
// [MinifyResult.Errors], [Validation.Diagnostics] or [LintReport.Diagnostics] —
// and the call itself succeeds. A returned error means the call could not be
// made or could not be trusted.
package wgslender
