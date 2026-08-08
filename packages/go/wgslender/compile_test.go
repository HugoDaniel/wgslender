package wgslender_test

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/tetratelabs/wazero"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// wasmMagic is the four bytes every WebAssembly module starts with.
var wasmMagic = []byte{0x00, 0x61, 0x73, 0x6d}

// TestCompile is the compilation table. A new scenario is a row.
//
// The rows mirror the ones packages/rust/wgslender-core/tests/compile.rs pins,
// so the two bindings can be read against each other, and add the round trip
// the npm suite does and Rust cannot: running the module that comes out.
func TestCompile(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		check  func(*testing.T, string, wgslender.CompiledShader)
	}{
		{
			name:   "the demo shader compiles to a module smaller than its source",
			source: demoWGSL,
			check: func(t *testing.T, source string, got wgslender.CompiledShader) {
				if !bytes.HasPrefix(got.WASM, wasmMagic) {
					t.Errorf("WASM starts % x, want the wasm magic % x", got.WASM[:min(4, len(got.WASM))], wasmMagic)
				}
				if got.OriginalSize != len(source) {
					t.Errorf("OriginalSize = %d, want %d — it is the size of the input, not of the module",
						got.OriginalSize, len(source))
				}
				if len(got.WASM) >= len(source) {
					t.Errorf("a %d-byte shader compiled to %d bytes, which buys nothing",
						len(source), len(got.WASM))
				}
			},
		},
		{
			name:   "a vertex/fragment pair compiles too",
			source: renderWGSL,
			check: func(t *testing.T, _ string, got wgslender.CompiledShader) {
				if !bytes.HasPrefix(got.WASM, wasmMagic) {
					t.Error("not a wasm module")
				}
			},
		},
		{
			name:   "a semantically invalid shader still compiles",
			source: invalidWGSL,
			check: func(t *testing.T, _ string, got wgslender.CompiledShader) {
				// The compiler never type-checks: it minifies text and packs
				// it. An undeclared name is Validate's business, not its.
				if !bytes.HasPrefix(got.WASM, wasmMagic) {
					t.Error("an undeclared name must not stop the compiler")
				}
			},
		},
		{
			name:   "an empty shader compiles to a module that generates nothing",
			source: "",
			check: func(t *testing.T, _ string, got wgslender.CompiledShader) {
				if !bytes.HasPrefix(got.WASM, wasmMagic) {
					t.Error("an empty shader is still a shader")
				}
				if got.OriginalSize != 0 {
					t.Errorf("OriginalSize = %d, want 0", got.OriginalSize)
				}
				if wgsl := regenerate(t, got); wgsl != "" {
					t.Errorf("the module generated %q, want nothing", wgsl)
				}
			},
		},
		{
			name:   "a shader whose only content is a comment compiles to nothing as well",
			source: "// nothing to see here\n",
			check: func(t *testing.T, source string, got wgslender.CompiledShader) {
				if got.OriginalSize != len(source) {
					t.Errorf("OriginalSize = %d, want %d", got.OriginalSize, len(source))
				}
				if wgsl := regenerate(t, got); wgsl != "" {
					t.Errorf("the module generated %q, want nothing", wgsl)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Compile(t.Context(), tt.source, nil)
			if err != nil {
				t.Fatalf("Compile() error = %v, want none", err)
			}
			tt.check(t, tt.source, got)
		})
	}
}

// TestCompiledModuleRegeneratesTheShader runs what Compile produced.
//
// This is the assertion the whole subcommand rests on, and the one a header
// check cannot stand in for: a module can carry the right four magic bytes and
// still fail to instantiate, or instantiate and hand back the wrong text. Only
// running it settles that.
func TestCompiledModuleRegeneratesTheShader(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		// wants are substrings the regenerated WGSL must contain. They are
		// deliberately structural — attributes, binding declarations, entry
		// point names — because everything else is renamed by minification.
		wants []string
	}{
		{
			name:   "a compute entry point survives the round trip",
			source: "@compute @workgroup_size(1) fn main() {}",
			wants:  []string{"@compute", "@workgroup_size(1)", "fn main()"},
		},
		{
			name:   "the demo shader's interface survives it",
			source: demoWGSL,
			wants: []string{
				"@compute",
				"@workgroup_size(8,8,1)",
				"@group(0) @binding(0) var<uniform> params:",
				"@group(0) @binding(1) var<storage,read_write> data:",
				"@group(1) @binding(0)",
				"@group(1) @binding(1)",
				"fn main(",
			},
		},
		{
			name:   "both of a render pair's entry points survive it",
			source: renderWGSL,
			wants:  []string{"@vertex", "fn vs_main(", "@fragment", "fn fs_main(", "@location(0)"},
		},
		{
			name:   "overrides, an alias's expansion and a storage texture survive it",
			source: overridesWGSL,
			wants: []string{
				"override grid",
				"@id(42)",
				"texture_storage_2d<rgba8unorm,write>",
				"@workgroup_size(grid)",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			compiled, err := wgslender.Compile(t.Context(), tt.source, nil)
			if err != nil {
				t.Fatalf("Compile() error = %v, want none", err)
			}
			wgsl := regenerate(t, compiled)
			for _, want := range tt.wants {
				if !strings.Contains(wgsl, want) {
					t.Errorf("the regenerated WGSL does not contain %q\ngot: %s", want, wgsl)
				}
			}
		})
	}
}

// TestRegeneratedShaderStillValidates closes the loop the other way: the text
// that comes back out is not merely shaped like WGSL, it is WGSL this engine
// accepts.
func TestRegeneratedShaderStillValidates(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name   string
		source string
	}{
		{"demo", demoWGSL},
		{"render", renderWGSL},
		{"overrides", overridesWGSL},
		{"holes", holesWGSL},
		{"layout", layoutWGSL},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			compiled, err := wgslender.Compile(t.Context(), tt.source, nil)
			if err != nil {
				t.Fatalf("Compile() error = %v, want none", err)
			}
			got, err := wgslender.Validate(t.Context(), regenerate(t, compiled), wgslender.DefaultStrictness)
			if err != nil {
				t.Fatalf("Validate() error = %v, want none", err)
			}
			if !got.Valid {
				t.Errorf("the regenerated shader does not validate: %+v", got.Diagnostics)
			}
		})
	}
}

// TestCompiledModuleIsSelfContained pins the contract that makes the output
// worth shipping: it needs nothing from its host.
//
// A module with an import is one the caller has to build an environment for,
// and the whole point of compiling a shader this way is that
// WebAssembly.instantiate(bytes) — with no import object at all — is enough.
func TestCompiledModuleIsSelfContained(t *testing.T) {
	t.Parallel()

	compiled, err := wgslender.Compile(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Compile() error = %v, want none", err)
	}

	ctx := t.Context()
	rt := wazero.NewRuntime(ctx)
	t.Cleanup(func() { _ = rt.Close(context.Background()) })

	mod, err := rt.CompileModule(ctx, compiled.WASM)
	if err != nil {
		t.Fatalf("the produced module does not compile: %v", err)
	}
	if imports := mod.ImportedFunctions(); len(imports) != 0 {
		t.Errorf("the produced module imports %d functions, want none", len(imports))
	}
	if imports := mod.ImportedMemories(); len(imports) != 0 {
		t.Errorf("the produced module imports %d memories, want none", len(imports))
	}

	fns := mod.ExportedFunctions()
	if len(fns) != 1 {
		t.Errorf("the produced module exports %d functions, want only generate()", len(fns))
	}
	if _, ok := fns["generate"]; !ok {
		t.Error("the produced module exports no generate()")
	}
	if _, ok := mod.ExportedMemories()["memory"]; !ok {
		t.Error("the produced module exports no memory, so nothing can read what generate() wrote")
	}
}

// TestCompileOptions says which of [wgslender.MinifyOptions] the compiler
// listens to.
//
// It listens to four of the eleven. The rest describe how text is printed, and
// the compiler prints with a configuration of its own that no caller can reach
// — so passing them is not an error, it is simply ignored. That distinction is
// invisible from the type, which is exactly why it is pinned here rather than
// only described in a doc comment.
func TestCompileOptions(t *testing.T) {
	t.Parallel()

	on, off := wgslender.Set(true), wgslender.Set(false)

	tests := []struct {
		name   string
		source string
		opts   *wgslender.MinifyOptions
		// effective says whether the option changes the module at all.
		effective bool
		// check, when set, receives the regenerated WGSL, so a row can say
		// what the option did rather than only that it did something.
		check func(*testing.T, string)
	}{
		{
			name:      "MinifyIdentifiers off keeps the author's names",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{MinifyIdentifiers: off},
			effective: true,
			check: func(t *testing.T, wgsl string) {
				if !strings.Contains(wgsl, "luminance") {
					t.Errorf("the helper was renamed anyway\ngot: %s", wgsl)
				}
			},
		},
		{
			name:      "MangleExternalBindings renames the host-facing names too",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{MangleExternalBindings: on},
			effective: true,
			check: func(t *testing.T, wgsl string) {
				if strings.Contains(wgsl, "params") {
					t.Errorf("the uniform kept its name\ngot: %s", wgsl)
				}
			},
		},
		{
			name:      "KeepNames spares the names it lists",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{KeepNames: []string{"luminance"}},
			effective: true,
			check: func(t *testing.T, wgsl string) {
				if !strings.Contains(wgsl, "luminance") {
					t.Errorf("the kept name was renamed\ngot: %s", wgsl)
				}
				if strings.Contains(wgsl, "Params") {
					t.Error("KeepNames spared a name it was not given")
				}
			},
		},
		{
			name:      "TreeShaking off keeps what nothing calls",
			source:    unusedWGSL,
			opts:      &wgslender.MinifyOptions{TreeShaking: off},
			effective: true,
			check: func(t *testing.T, wgsl string) {
				if !strings.Contains(wgsl, "return a*2.0") {
					t.Errorf("the unreachable helper was dropped anyway\ngot: %s", wgsl)
				}
			},
		},
		{
			name:      "MinifyWhitespace is ignored",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{MinifyWhitespace: off},
			effective: false,
		},
		{
			name:      "MinifySyntax is ignored",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{MinifySyntax: off},
			effective: false,
		},
		{
			name:      "SortDeclarations is ignored, because the compiler always sorts",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{SortDeclarations: off},
			effective: false,
		},
		{
			name:      "ScopeLocalRename is ignored, because the compiler always does it",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{ScopeLocalRename: off},
			effective: false,
		},
		{
			name:      "PreserveUniformStructTypes is ignored",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{PreserveUniformStructTypes: on},
			effective: false,
		},
		{
			name:      "SourceMap is ignored, there being nowhere to put one",
			source:    demoWGSL,
			opts:      &wgslender.MinifyOptions{SourceMap: on, SourceMapSources: on},
			effective: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			base, err := wgslender.Compile(t.Context(), tt.source, nil)
			if err != nil {
				t.Fatalf("Compile() with defaults: %v", err)
			}
			got, err := wgslender.Compile(t.Context(), tt.source, tt.opts)
			if err != nil {
				t.Fatalf("Compile() error = %v, want none", err)
			}

			if changed := !bytes.Equal(base.WASM, got.WASM); changed != tt.effective {
				t.Errorf("the option changed the module = %v, want %v (%d bytes vs %d)",
					changed, tt.effective, len(got.WASM), len(base.WASM))
			}
			if got.OriginalSize != base.OriginalSize {
				t.Errorf("OriginalSize = %d, want %d — the input did not change",
					got.OriginalSize, base.OriginalSize)
			}
			if tt.check != nil {
				tt.check(t, regenerate(t, got))
			}
		})
	}
}

// TestCompilePrintsWithItsOwnSettings names the configuration the compiler
// substitutes for the caller's, by reproducing its output through [Minify].
//
// It is the same shader through the same printer, so the two must agree
// exactly; if they ever stop agreeing, the settings named here have moved.
func TestCompilePrintsWithItsOwnSettings(t *testing.T) {
	t.Parallel()

	compiled, err := wgslender.Compile(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Compile() error = %v, want none", err)
	}
	generated := regenerate(t, compiled)

	forced, err := wgslender.Minify(t.Context(), demoWGSL, &wgslender.MinifyOptions{
		SortDeclarations: wgslender.Set(true),
		ScopeLocalRename: wgslender.Set(true),
		MinifySyntax:     wgslender.Set(false),
	})
	if err != nil {
		t.Fatalf("Minify() error = %v, want none", err)
	}
	if generated != forced.Code {
		t.Errorf("the compiler's own settings are no longer sort + scope-local rename + no syntax rewriting\ngenerated: %s\nminified:  %s",
			generated, forced.Code)
	}

	// And the point of naming them: they are not the defaults, so a caller
	// who compiles does not get the text Minify would have given them.
	def, err := wgslender.Minify(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Minify() error = %v, want none", err)
	}
	if generated == def.Code {
		t.Error("compiling and minifying now agree, so this test no longer says anything")
	}
}

// TestCompileUnparseable pins the one input class that yields no module.
func TestCompileUnparseable(t *testing.T) {
	t.Parallel()

	got, err := wgslender.Compile(t.Context(), unparseableWGSL, nil)
	if err == nil {
		t.Fatal("Compile() of unparseable source returned no error; an empty module is not an answer")
	}
	if got.WASM != nil || got.OriginalSize != 0 {
		t.Errorf("Compile() returned %+v alongside its error, want the zero value", got)
	}

	var cerr *wgslender.CompileError
	if !errors.As(err, &cerr) {
		t.Fatalf("Compile() error = %v (%T), want a *wgslender.CompileError", err, err)
	}
	if len(cerr.Diagnostics) == 0 {
		t.Fatal("a compile error must say what went wrong")
	}
	first := cerr.Diagnostics[0]
	if first.Line < 1 || first.Column < 1 {
		t.Errorf("the first diagnostic is at %d:%d, want 1-based positions", first.Line, first.Column)
	}
	if first.Message == "" {
		t.Error("the first diagnostic has no message")
	}
	if first.Severity != wgslender.SeverityError {
		t.Errorf("Severity = %q, want %q", first.Severity, wgslender.SeverityError)
	}
	if !strings.Contains(err.Error(), first.Message) {
		t.Errorf("Error() = %q, which does not mention the first diagnostic %q", err.Error(), first.Message)
	}
}

// TestCompileReportsEveryParseError checks that the diagnostics are the whole
// list rather than the first one. Recovery finds several errors per broken
// shader and dropping the rest would send the caller back for another round.
func TestCompileReportsEveryParseError(t *testing.T) {
	t.Parallel()

	one, err := wgslender.Compile(t.Context(), "fn a( { let ; }", nil)
	if err == nil {
		t.Fatalf("Compile() returned %+v, want an error", one)
	}
	var single *wgslender.CompileError
	if !errors.As(err, &single) {
		t.Fatalf("Compile() error = %v (%T), want a *wgslender.CompileError", err, err)
	}

	_, err = wgslender.Compile(t.Context(), "fn a( { let ; }\nfn b( { let ; }", nil)
	if err == nil {
		t.Fatal("Compile() of two broken functions returned no error")
	}
	var double *wgslender.CompileError
	if !errors.As(err, &double) {
		t.Fatalf("Compile() error = %v (%T), want a *wgslender.CompileError", err, err)
	}

	if len(double.Diagnostics) <= len(single.Diagnostics) {
		t.Errorf("two broken functions produced %d diagnostics and one produced %d; only the first error is being reported",
			len(double.Diagnostics), len(single.Diagnostics))
	}
	// The second function's errors are on line 2, which is the cheapest proof
	// that recovery kept going rather than repeating itself.
	var beyondTheFirstLine bool
	for _, d := range double.Diagnostics {
		if d.Line > 1 {
			beyondTheFirstLine = true
		}
	}
	if !beyondTheFirstLine {
		t.Errorf("every diagnostic is on line 1: %+v", double.Diagnostics)
	}
}

// TestCompileNilOptionsMatchZero pins the promise MinifyOptions makes: nothing
// to say can be said by saying nothing.
func TestCompileNilOptionsMatchZero(t *testing.T) {
	t.Parallel()

	viaNil, err := wgslender.Compile(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Compile() with nil options: %v", err)
	}
	viaZero, err := wgslender.Compile(t.Context(), demoWGSL, &wgslender.MinifyOptions{})
	if err != nil {
		t.Fatalf("Compile() with zero options: %v", err)
	}
	if !bytes.Equal(viaNil.WASM, viaZero.WASM) {
		t.Error("nil options and zero options produced different modules")
	}
}

func TestCompileRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	if _, err := wgslender.Compile(t.Context(), "let\x95", nil); !errors.Is(err, wgslender.ErrInvalidUTF8) {
		t.Errorf("Compile() error = %v, want ErrInvalidUTF8", err)
	}
}

// regenerate runs a compiled shader the way its host will: instantiate the
// module with no imports at all, call generate(), and read the WGSL it wrote at
// offset 0.
func regenerate(t *testing.T, compiled wgslender.CompiledShader) string {
	t.Helper()

	ctx := t.Context()
	rt := wazero.NewRuntime(ctx)
	// Closing takes a fresh context: t.Context() is already cancelled by the
	// time cleanups run, and the runtime still has to be torn down.
	t.Cleanup(func() { _ = rt.Close(context.Background()) })

	mod, err := rt.InstantiateWithConfig(ctx, compiled.WASM, wazero.NewModuleConfig().WithName(""))
	if err != nil {
		t.Fatalf("instantiating the compiled module: %v", err)
	}
	generate := mod.ExportedFunction("generate")
	if generate == nil {
		t.Fatal("the compiled module exports no generate()")
	}
	out, err := generate.Call(ctx)
	if err != nil {
		t.Fatalf("calling generate(): %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("generate() returned %d values, want 1", len(out))
	}
	n := uint32(out[0])
	wgsl, ok := mod.Memory().Read(0, n)
	if !ok {
		t.Fatalf("generate() reported %d bytes, which are not in the module's memory", n)
	}
	return string(wgsl)
}
