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
// Every function that reaches the engine takes a [context.Context] first, and
// all of them are safe to call from any number of goroutines.
//
// Behind them is a small pool of WebAssembly instances — one per processor, up
// to eight, built on demand. One instance is one single-threaded allocator, so
// each call has an instance to itself while it runs and the pool is what lets
// independent calls still run at the same time. A program that never calls
// from two goroutines at once never builds more than one instance; each holds
// a couple of megabytes, and one that grows unusually large after an unusually
// large shader is discarded rather than kept.
//
// Cancelling a context stops a call from starting: it will not queue for an
// instance, and it returns an error wrapping [context.Canceled] or
// [context.DeadlineExceeded]. It does not interrupt a call already running.
// wazero can be asked to check for cancellation inside the guest, but that
// costs four and a half times the run time of every call, which is a poor
// trade against work measured in tens of microseconds.
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
// [MinifyResult.Errors], [Validation.Diagnostics], [LintReport.Diagnostics] or
// [Reflection.Errors] — and the call itself succeeds. A returned error means
// the call could not be made or could not be trusted.
//
// The exceptions are the calls that have nothing to report when they fail.
// [Compile] is one: every other function still has an answer for a shader it
// could not read, while a compiler with nothing to compile has no module to
// hand back, so source that does not parse is a *[CompileError] there. The
// refactor operations are the rest — a rename that cannot be performed has no
// edits, and an empty edit list would say the opposite, that there was nothing
// to do. Their reasons are sentinels: [ErrSymbolNotFound],
// [ErrInvalidIdentifier], [ErrNotRemovable] and their kin.
//
// # Refactoring
//
// Twelve operations work on a shader's symbols rather than on its text as a
// whole: finding where a symbol is mentioned, renaming it, retyping it,
// removing it.
//
// Address the symbol either by a byte offset into the source or by a
// [StableID]. An offset is what a cursor gives you, and it stops being right
// the moment anything before it changes; a StableID names the symbol itself
// and survives edits elsewhere in the file. [StableIDAtOffset] turns one into
// the other, and [Reflect] hands out IDs for everything it describes.
//
// The ones that change something come in pairs. The plain form — [Rename],
// [ChangeType], [RemoveDeclaration] — returns [Edit] values and changes
// nothing, which is what an editor wants, having its own buffer to splice into
// and its own undo stack to record. The Apply form does the splicing and hands
// back the rewritten source, which is what a script wants.
//
// None of them type-check what they produce. A rename can collide, a removed
// function leaves its callers behind, and a replacement type is spliced in
// verbatim whether or not it is a type. Run [Validate] on the result when that
// matters.
package wgslender
