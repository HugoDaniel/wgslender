package wgslender

import (
	"context"
	"encoding/json"
	"fmt"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
)

// compileFn is the guest export behind [Compile].
const compileFn = "wgslender_compile"

// A CompiledShader is a WebAssembly module that hands back one shader.
//
// It is a compressed shader, not a compiled pipeline: the module carries the
// minified WGSL byte-pair encoded, behind a decoder of about a hundred bytes,
// and the text it produces still goes to createShaderModule on the other side.
type CompiledShader struct {
	// WASM is the module. It imports nothing, so instantiating it needs no
	// import object and no host functions, and it exports exactly two things:
	// generate() and the memory it writes into.
	WASM []byte
	// OriginalSize is the byte length of the WGSL that was handed in — not of
	// the module, and not of the text the module expands to, which is smaller
	// because it is minified. Compare it against len(WASM) for what compiling
	// bought.
	OriginalSize int
}

// A CompileError reports a shader [Compile] could not read.
//
// It is the one place in this package where a shader's own problem is a Go
// error rather than data. Everywhere else there is still an answer to give —
// minification hands back the original source, validation hands back
// diagnostics — but a compiler with nothing to compile has no module to
// return, and an empty module is not an answer.
type CompileError struct {
	// Diagnostics is every parse error, in source order, not just the first.
	Diagnostics []Diagnostic
}

// Error reports the first parse error, and how many followed it. The rest are
// in [CompileError.Diagnostics], with their positions.
func (e *CompileError) Error() string {
	if len(e.Diagnostics) == 0 {
		// The engine never does this — it withholds a module only when it has
		// something to say about why — but a zero CompileError should still
		// print as an error rather than as a bare colon.
		return "wgslender: the shader does not compile"
	}
	d := e.Diagnostics[0]
	if rest := len(e.Diagnostics) - 1; rest > 0 {
		return fmt.Sprintf("wgslender: the shader does not compile: %s (line %d, column %d), and %d more",
			d.Message, d.Line, d.Column, rest)
	}
	return fmt.Sprintf("wgslender: the shader does not compile: %s (line %d, column %d)",
		d.Message, d.Line, d.Column)
}

// Compile turns a shader into a WebAssembly module that regenerates it at run
// time. A nil opts means wgslender's defaults; see [MinifyOptions].
//
// Run what comes back with any WebAssembly host. In Go that is the same wazero
// this package already depends on:
//
//	compiled, err := wgslender.Compile(ctx, source, nil)
//	// …
//	runtime := wazero.NewRuntime(ctx)
//	defer runtime.Close(ctx)
//
//	mod, err := runtime.Instantiate(ctx, compiled.WASM)
//	// …
//	out, err := mod.ExportedFunction("generate").Call(ctx)
//	// …
//	wgsl, _ := mod.Memory().Read(0, uint32(out[0]))
//
// # Which options apply
//
// Four of them: [MinifyOptions.MinifyIdentifiers],
// [MinifyOptions.MangleExternalBindings], [MinifyOptions.KeepNames] and
// [MinifyOptions.TreeShaking]. Those decide what the shader says.
//
// The rest decide how it is written down, and the compiler overrides them: it
// always sorts declarations and reuses short names across sibling scopes,
// because both compress better, and it leaves the syntax rewrites off. So
// setting MinifyWhitespace, MinifySyntax, SortDeclarations, ScopeLocalRename,
// PreserveUniformStructTypes or either source-map option changes nothing here.
// They are ignored rather than refused, since they are the same options type
// [Minify] takes.
//
// One consequence worth expecting: the text the module expands to is not the
// text Minify would have produced from the same shader with the same options.
//
// # Errors
//
// A shader that does not parse is a *[CompileError] carrying the parse errors,
// because there is no module to hand back:
//
//	if cerr, ok := errors.AsType[*wgslender.CompileError](err); ok {
//		for _, d := range cerr.Diagnostics { … }
//	}
//
// A shader that parses always compiles, however little sense it makes: the
// compiler never type-checks, so an undeclared name or a type mismatch reaches
// the module untouched. Call [Validate] if you need to know.
//
// The other errors are the usual ones for a call that could not be made or
// trusted — [ErrInvalidUTF8], [ErrSourceTooLarge], [ErrInternal].
func Compile(ctx context.Context, source string, opts *MinifyOptions) (CompiledShader, error) {
	if err := checkUTF8("source", source); err != nil {
		return CompiledShader{}, err
	}
	encoded, err := opts.encode()
	if err != nil {
		return CompiledShader{}, err
	}
	res, err := wasmabi.Call(ctx, compileFn, wasmabi.PackCompile,
		wasmabi.Buffer([]byte(source)), wasmabi.Buffer(encoded))
	if err != nil {
		return CompiledShader{}, err
	}

	// This envelope carries the diagnostics as a bare JSON array, where
	// validate and lint wrap theirs in an object. The entries themselves are
	// the same shape, so only the outer decoding differs.
	var ws []wireDiagnostic
	if err := json.Unmarshal(res.Payloads[1], &ws); err != nil {
		return CompiledShader{}, fmt.Errorf("wgslender: decoding the compile diagnostics: %w", err)
	}
	if len(ws) > 0 {
		return CompiledShader{}, &CompileError{Diagnostics: diagnostics(ws)}
	}

	// Today the engine sends diagnostics for every module it withholds, so
	// this is unreachable. It is checked anyway because the alternative is
	// returning an empty WASM field that looks like a success and fails at
	// instantiation, a long way from here.
	if len(res.Payloads[0]) == 0 {
		return CompiledShader{}, fmt.Errorf("%w: %s produced no module and said nothing about why", ErrInternal, compileFn)
	}
	return CompiledShader{WASM: res.Payloads[0], OriginalSize: int(res.Words[1])}, nil
}
