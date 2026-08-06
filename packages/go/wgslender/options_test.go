package wgslender_test

import (
	"encoding/json"
	"testing"

	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// TestMinifyOptionsJSON pins the wire spelling of every option, because the
// guest cannot report a misspelled key: unknown keys are ignored, and a
// malformed options object is swallowed entirely (Config.parseJson ... catch
// Config{} in src/api_json.zig). A typo here would not fail, it would silently
// minify with the defaults.
func TestMinifyOptionsJSON(t *testing.T) {
	tests := []struct {
		name string
		opts wgslender.MinifyOptions
		want string
	}{
		{
			name: "the zero value asks for nothing",
			opts: wgslender.MinifyOptions{},
			want: `{}`,
		},
		{
			name: "false is a value, not an absence",
			opts: wgslender.MinifyOptions{
				MinifyWhitespace: wgslender.Set(true),
				TreeShaking:      wgslender.Set(false),
				KeepNames:        []string{"main"},
			},
			want: `{"minifyWhitespace":true,"treeShaking":false,"keepNames":["main"]}`,
		},
		{
			// Every key at once, in field order, so a rename or a dropped
			// option fails here rather than in whichever behaviour test
			// happened to use it.
			name: "every option spells its camelCase key",
			opts: wgslender.MinifyOptions{
				MinifyWhitespace:           wgslender.Set(true),
				MinifyIdentifiers:          wgslender.Set(true),
				MinifySyntax:               wgslender.Set(true),
				TreeShaking:                wgslender.Set(true),
				MangleExternalBindings:     wgslender.Set(true),
				PreserveUniformStructTypes: wgslender.Set(true),
				KeepNames:                  []string{"a", "b"},
				SortDeclarations:           wgslender.Set(true),
				ScopeLocalRename:           wgslender.Set(true),
				SourceMap:                  wgslender.Set(true),
				SourceMapSources:           wgslender.Set(true),
			},
			want: `{"minifyWhitespace":true,"minifyIdentifiers":true,"minifySyntax":true,` +
				`"treeShaking":true,"mangleExternalBindings":true,"preserveUniformStructTypes":true,` +
				`"keepNames":["a","b"],"sortDeclarations":true,"scopeLocalRename":true,` +
				`"sourceMap":true,"sourceMapSources":true}`,
		},
		{
			// omitzero drops a nil slice but keeps an explicitly empty one.
			// Both mean "keep nothing" to the guest; the difference is only
			// visible on the wire, and this pins which side of it we are on.
			name: "a nil keepNames disappears",
			opts: wgslender.MinifyOptions{MinifySyntax: wgslender.Set(false)},
			want: `{"minifySyntax":false}`,
		},
		{
			name: "an empty keepNames is sent as an empty list",
			opts: wgslender.MinifyOptions{KeepNames: []string{}},
			want: `{"keepNames":[]}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.opts)
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			if string(got) != tt.want {
				t.Errorf("Marshal =\n %s\nwant\n %s", got, tt.want)
			}
		})
	}
}

// TestOptGet pins the accessor, which is the only way out of an Opt and so the
// only way a caller can tell "set to false" from "never set".
func TestOptGet(t *testing.T) {
	var absent wgslender.Opt[bool]
	if v, ok := absent.Get(); ok || v {
		t.Errorf("zero Opt.Get() = (%v, %v), want (false, false)", v, ok)
	}
	if v, ok := wgslender.Set(false).Get(); !ok || v {
		t.Errorf("Set(false).Get() = (%v, %v), want (false, true)", v, ok)
	}
	if v, ok := wgslender.Set("x").Get(); !ok || v != "x" {
		t.Errorf(`Set("x").Get() = (%v, %v), want ("x", true)`, v, ok)
	}
}

// TestOptRoundTrip keeps Opt honest as a JSON type in both directions. Nothing
// in this package decodes into one today, but a type that marshals and does not
// unmarshal fails by quietly producing zero values, which is the failure mode
// worth spending four lines to rule out.
func TestOptRoundTrip(t *testing.T) {
	var got struct {
		A wgslender.Opt[bool] `json:"a,omitzero"`
		B wgslender.Opt[int]  `json:"b,omitzero"`
	}
	if err := json.Unmarshal([]byte(`{"a":false}`), &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if v, ok := got.A.Get(); !ok || v {
		t.Errorf("A = (%v, %v), want (false, true)", v, ok)
	}
	if _, ok := got.B.Get(); ok {
		t.Error("B was set by a document that never mentioned it")
	}
}
