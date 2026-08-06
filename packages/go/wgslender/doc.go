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
// calls do not. This is the one place the API deliberately diverges from the
// npm package, which makes the caller await an explicit initialize().
//
// # Contexts and concurrency
//
// Every function that reaches the engine takes a [context.Context] first.
// All of them are safe to call from multiple goroutines, though calls are
// serialised: the engine is a single-threaded allocator and running two calls
// through it at once corrupts its heap.
package wgslender
