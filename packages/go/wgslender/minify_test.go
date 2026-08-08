package wgslender_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// TestMinify is the behaviour table: one row per scenario, each row naming what
// it believes about the minifier. The expectations come from the sibling
// bindings' own suites (packages/rust/wgslender-core/tests/minify.rs and
// packages/js-npm/test/_suite.cjs), so a divergence between the three shows up
// as a failure here rather than as three packages that quietly disagree.
func TestMinify(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		opts   *wgslender.MinifyOptions
		check  func(t *testing.T, source string, got wgslender.MinifyResult)
	}{
		{
			name:   "defaults shrink the source and keep the entry point",
			source: demoWGSL,
			check: func(t *testing.T, source string, got wgslender.MinifyResult) {
				if len(got.Code) >= len(source) {
					t.Errorf("minified to %d bytes, want fewer than %d", len(got.Code), len(source))
				}
				for _, want := range []string{"@compute", "fn main"} {
					if !strings.Contains(got.Code, want) {
						t.Errorf("%q must survive minification:\n%s", want, got.Code)
					}
				}
				if strings.Contains(got.Code, "luminance") {
					t.Errorf("helper functions are renamed by default:\n%s", got.Code)
				}
			},
		},
		{
			name:   "KeepNames preserves the named helper",
			source: demoWGSL,
			opts:   &wgslender.MinifyOptions{KeepNames: []string{"luminance"}},
			check: func(t *testing.T, source string, got wgslender.MinifyResult) {
				if !strings.Contains(got.Code, "luminance") {
					t.Errorf("a kept name must survive renaming:\n%s", got.Code)
				}
				if len(got.Code) >= len(source) {
					t.Error("keeping one name must not defeat minification")
				}
			},
		},
		{
			name:   "whitespace-only leaves every identifier alone",
			source: demoWGSL,
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace:  wgslender.Set(true),
				MinifyIdentifiers: wgslender.Set(false),
				MinifySyntax:      wgslender.Set(false),
				TreeShaking:       wgslender.Set(false),
			},
			check: func(t *testing.T, source string, got wgslender.MinifyResult) {
				for _, want := range []string{"params", "Params", "luminance", "resolution"} {
					if !strings.Contains(got.Code, want) {
						t.Errorf("%q must survive:\n%s", want, got.Code)
					}
				}
				if len(got.Code) >= len(source) {
					t.Error("whitespace must still go")
				}
			},
		},
		{
			name:   "an @group binding keeps its name by default",
			source: "@group(0) @binding(0) var<uniform> uniforms: f32;\nfn getValue() -> f32 { return uniforms * 2.0; }",
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace:  wgslender.Set(true),
				MinifyIdentifiers: wgslender.Set(true),
			},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if !strings.Contains(got.Code, "var<uniform> uniforms") {
					t.Errorf("the host binds against this name, so it is preserved:\n%s", got.Code)
				}
			},
		},
		{
			name:   "MangleExternalBindings renames it anyway",
			source: "@group(0) @binding(0) var<uniform> uniforms: f32;\nfn getValue() -> f32 { return uniforms * 2.0; }",
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace:       wgslender.Set(true),
				MinifyIdentifiers:      wgslender.Set(true),
				MangleExternalBindings: wgslender.Set(true),
			},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if strings.Contains(got.Code, "uniforms") {
					t.Errorf("the binding name should be gone:\n%s", got.Code)
				}
			},
		},
		{
			name: "TreeShaking drops what no entry point reaches",
			source: "fn used() -> f32 { return 1.0; }\nfn unused() -> f32 { return 2.0; }\n" +
				"@compute @workgroup_size(1) fn main() { let x = used(); }",
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace: wgslender.Set(true),
				TreeShaking:      wgslender.Set(true),
			},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if strings.Contains(got.Code, "unused") {
					t.Errorf("unreachable declarations should be gone:\n%s", got.Code)
				}
			},
		},
		{
			name: "PreserveUniformStructTypes keeps the struct's type name",
			source: "struct MyStruct { x: f32 }\n@group(0) @binding(0) var<uniform> u: MyStruct;\n" +
				"@compute @workgroup_size(1) fn main() { let v = u.x; }",
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace:           wgslender.Set(true),
				MinifyIdentifiers:          wgslender.Set(true),
				PreserveUniformStructTypes: wgslender.Set(true),
			},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if !strings.Contains(got.Code, "MyStruct") {
					t.Errorf("the uniform struct type should be intact:\n%s", got.Code)
				}
			},
		},
		{
			name:   "entry point names are preserved",
			source: "@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }",
			opts: &wgslender.MinifyOptions{
				MinifyWhitespace:  wgslender.Set(true),
				MinifyIdentifiers: wgslender.Set(true),
			},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if !strings.Contains(got.Code, "fn vs(") {
					t.Errorf("the pipeline names this function:\n%s", got.Code)
				}
			},
		},
		{
			name:   "a semantic error does not stop minification",
			source: invalidWGSL,
			check: func(t *testing.T, source string, got wgslender.MinifyResult) {
				if !strings.Contains(got.Code, "undeclared_variable") {
					t.Errorf("the unresolved name passes through untouched:\n%s", got.Code)
				}
				if len(got.Code) >= len(source) {
					t.Error("minification is not aborted by semantic errors")
				}
				if len(got.Errors) != 0 {
					t.Errorf("the minifier reports parse errors only, got %q", got.Errors)
				}
			},
		},
		{
			name:   "unparseable source comes back unchanged",
			source: unparseableWGSL,
			check: func(t *testing.T, source string, got wgslender.MinifyResult) {
				if got.Code != source {
					t.Errorf("Code = %q, want the source verbatim", got.Code)
				}
				if len(got.Errors) == 0 {
					t.Error("the parser's complaints should be reported")
				}
			},
		},
		{
			name:   "severely malformed input reports rather than crashes",
			source: "@@@@!!!###",
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if len(got.Errors) == 0 {
					t.Error("want errors")
				}
			},
		},
		{
			name:   "empty source minifies to nothing",
			source: "",
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if got.Code != "" {
					t.Errorf("Code = %q, want empty", got.Code)
				}
				if len(got.Errors) != 0 {
					t.Errorf("Errors = %q, want none", got.Errors)
				}
			},
		},
		{
			name:   "a comment-only source minifies away entirely",
			source: "// nothing but a comment\n",
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if got.Code != "" {
					t.Errorf("Code = %q, want empty", got.Code)
				}
			},
		},
		{
			name:   "an empty KeepNames keeps nothing and breaks nothing",
			source: "fn foo() -> f32 { return 1.0; }",
			opts:   &wgslender.MinifyOptions{KeepNames: []string{}},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if len(got.Errors) != 0 {
					t.Errorf("Errors = %q, want none", got.Errors)
				}
			},
		},
		{
			name:   "KeepNames may name identifiers the source does not have",
			source: "fn foo() -> f32 { return 1.0; }",
			opts:   &wgslender.MinifyOptions{KeepNames: []string{"nonexistent"}},
			check: func(t *testing.T, _ string, got wgslender.MinifyResult) {
				if len(got.Errors) != 0 {
					t.Errorf("Errors = %q, want none", got.Errors)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Minify(t.Context(), tt.source, tt.opts)
			if err != nil {
				t.Fatalf("Minify: %v", err)
			}
			tt.check(t, tt.source, got)
		})
	}
}

// TestMinifyReportsSizes pins the two size fields against what they describe.
// They are the only numbers in the envelope, and both are easy to believe
// without checking.
func TestMinifyReportsSizes(t *testing.T) {
	t.Parallel()

	got, err := wgslender.Minify(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Minify: %v", err)
	}
	if got.OriginalSize != len(demoWGSL) {
		t.Errorf("OriginalSize = %d, want %d", got.OriginalSize, len(demoWGSL))
	}
	if got.MinifiedSize != len(got.Code) {
		t.Errorf("MinifiedSize = %d, but Code is %d bytes", got.MinifiedSize, len(got.Code))
	}
	if got.MinifiedSize >= got.OriginalSize {
		t.Errorf("MinifiedSize = %d, want less than OriginalSize = %d", got.MinifiedSize, got.OriginalSize)
	}
}

// TestMinifyNilOptionsAreTheDefaults is the whole reason MinifyOptions has a
// useful zero value: an empty option set is not "everything off", it is
// "wgslender's own defaults apply". Nil, the zero struct and an empty JSON
// object all have to mean the same thing.
func TestMinifyNilOptionsAreTheDefaults(t *testing.T) {
	t.Parallel()

	viaNil, err := wgslender.Minify(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Minify(nil): %v", err)
	}
	viaZero, err := wgslender.Minify(t.Context(), demoWGSL, &wgslender.MinifyOptions{})
	if err != nil {
		t.Fatalf("Minify(&MinifyOptions{}): %v", err)
	}
	if viaNil.Code != viaZero.Code {
		t.Errorf("nil options produced different code:\n%s\n%s", viaNil.Code, viaZero.Code)
	}
}

// TestMinifySourceMap pins the one optional field in the envelope: absent
// unless asked for, and a v3 source map when it is.
func TestMinifySourceMap(t *testing.T) {
	t.Parallel()

	const src = "fn foo() -> f32 { return 1.0; }\nfn bar() -> f32 { return foo(); }"

	without, err := wgslender.Minify(t.Context(), src, nil)
	if err != nil {
		t.Fatalf("Minify: %v", err)
	}
	if without.SourceMap != nil {
		t.Errorf("SourceMap = %s, want nil when it was not requested", without.SourceMap)
	}

	with, err := wgslender.Minify(t.Context(), src, &wgslender.MinifyOptions{SourceMap: wgslender.Set(true)})
	if err != nil {
		t.Fatalf("Minify: %v", err)
	}
	if with.SourceMap == nil {
		t.Fatal("SourceMap = nil, want a source map")
	}
	var sm struct {
		Version  int      `json:"version"`
		Mappings string   `json:"mappings"`
		Names    []string `json:"names"`
		Sources  []string `json:"sources"`
	}
	if err := json.Unmarshal(with.SourceMap, &sm); err != nil {
		t.Fatalf("decoding the source map: %v", err)
	}
	if sm.Version != 3 {
		t.Errorf("source map version = %d, want 3", sm.Version)
	}
	if sm.Mappings == "" {
		t.Error("source map has no mappings")
	}
}

// TestMinifyIsIdempotent pins the property that makes minified output safe to
// keep in a build cache: running the minifier over its own output changes
// nothing. It is checked across option combinations because the passes that
// could break it — renaming, syntax rewriting, tree shaking — are individually
// switchable.
func TestMinifyIsIdempotent(t *testing.T) {
	t.Parallel()

	sources := map[string]string{
		"demo":    demoWGSL,
		"render":  renderWGSL,
		"warning": warningWGSL,
	}
	// Three independent switches, all eight settings. The other options do not
	// rewrite names or structure, so they cannot affect the fixed point.
	combos := []wgslender.MinifyOptions{}
	for _, whitespace := range []bool{false, true} {
		for _, identifiers := range []bool{false, true} {
			for _, syntax := range []bool{false, true} {
				combos = append(combos, wgslender.MinifyOptions{
					MinifyWhitespace:  wgslender.Set(whitespace),
					MinifyIdentifiers: wgslender.Set(identifiers),
					MinifySyntax:      wgslender.Set(syntax),
				})
			}
		}
	}

	for name, source := range sources {
		for i, opts := range combos {
			t.Run(fmt.Sprintf("%s/combo%d", name, i), func(t *testing.T) {
				t.Parallel()
				once, err := wgslender.Minify(t.Context(), source, &opts)
				if err != nil {
					t.Fatalf("Minify: %v", err)
				}
				twice, err := wgslender.Minify(t.Context(), once.Code, &opts)
				if err != nil {
					t.Fatalf("re-Minify: %v", err)
				}
				if twice.Code != once.Code {
					t.Errorf("%+v is not a fixed point:\n once: %s\ntwice: %s",
						opts, once.Code, twice.Code)
				}
			})
		}
	}
}

// TestMinifyRejectsInvalidUTF8 pins the boundary Go has to police itself.
//
// WGSL is UTF-8 text, but a Go string is only bytes, so a caller can hand this
// package something that is not WGSL at all. The engine does not notice: it
// copies the stray bytes into its JSON reply, where they are no longer valid
// JSON either, and encoding/json quietly substitutes U+FFFD. Accepting that
// would mean returning a shader whose bytes are not the caller's — refusing it
// is the only answer that stays true.
func TestMinifyRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	// Valid UTF-8 above ASCII must still go through: the check rejects
	// malformed encodings, not non-English shaders.
	if _, err := wgslender.Minify(t.Context(), "// 🎨 palette\nfn main() {}", nil); err != nil {
		t.Errorf("Minify of a valid non-ASCII shader: %v", err)
	}

	got, err := wgslender.Minify(t.Context(), "let\x95", nil)
	if !errors.Is(err, wgslender.ErrInvalidUTF8) {
		t.Fatalf("Minify = (%+v, %v), want ErrInvalidUTF8", got, err)
	}
	if got.Code != "" {
		t.Errorf("Code = %q, want the zero result alongside the error", got.Code)
	}
}

// TestMinifiedOutputStillValidates is the other half of the idempotence
// property: a minifier that produced a fixed point of broken code would satisfy
// the test above perfectly well. This one says the fixed point is a shader.
func TestMinifiedOutputStillValidates(t *testing.T) {
	t.Parallel()

	sources := map[string]string{
		"demo":   demoWGSL,
		"render": renderWGSL,
		"helper": "fn helper() -> f32 { return 1.0; }\n" +
			"@compute @workgroup_size(1) fn main() { let x = helper(); }",
	}

	for name, source := range sources {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Minify(t.Context(), source, nil)
			if err != nil {
				t.Fatalf("Minify: %v", err)
			}
			report, err := wgslender.Validate(t.Context(), got.Code, wgslender.DefaultStrictness)
			if err != nil {
				t.Fatalf("Validate: %v", err)
			}
			if !report.Valid {
				t.Errorf("minified output does not validate: %+v\n%s", report.Diagnostics, got.Code)
			}
		})
	}
}

// FuzzMinify asserts that no byte string can make the minifier lie. Valid
// UTF-8 must be answered — no shader is bad enough to be an error — and the
// answer's reported sizes must describe the answer. Anything else must be
// refused by name.
//
// The size check is the part with teeth. It caught the engine copying a stray
// 0x95 byte through into its JSON reply, which every JSON decoder then
// substitutes U+FFFD for, silently: the sizes disagreed because the bytes had
// been rewritten in transit. See [wgslender.ErrInvalidUTF8].
func FuzzMinify(f *testing.F) {
	for _, seed := range []string{
		demoWGSL,
		renderWGSL,
		invalidWGSL,
		warningWGSL,
		unparseableWGSL,
		"",
		"😀",
		"/* nested /* comments */ are legal in WGSL */ fn main() {}",
		"enable f16;\nfn main() { let x = 1h; }",
		"@group(0) @binding(0) var<storage, read_write> b: array<u32>;",
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, source string) {
		got, err := wgslender.Minify(t.Context(), source, nil)
		if !utf8.ValidString(source) {
			if !errors.Is(err, wgslender.ErrInvalidUTF8) {
				t.Fatalf("Minify(%q) = %v, want ErrInvalidUTF8", source, err)
			}
			return
		}
		if err != nil {
			t.Fatalf("Minify(%q): %v", source, err)
		}
		if got.MinifiedSize != len(got.Code) {
			t.Fatalf("MinifiedSize = %d but Code is %d bytes", got.MinifiedSize, len(got.Code))
		}
		if got.OriginalSize != len(source) {
			t.Fatalf("OriginalSize = %d, want %d", got.OriginalSize, len(source))
		}
	})
}
