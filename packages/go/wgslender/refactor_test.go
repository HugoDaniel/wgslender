package wgslender_test

// The twelve refactor operations, as tables. A new scenario is a row.
//
// Every offset here is computed from its fixture with strings.Index rather
// than written down as a number, because the ABI speaks UTF-8 byte offsets and
// strings.Index is the thing in Go that produces one.
//
// The expectations were probed against the live wasm before they were written
// down. Three of them contradict what the operations' names suggest, and each
// has a test of its own: removing a declaration leaves the calls to it
// dangling, changing a type accepts a replacement that is not a type, and the
// locate family reports absence as an answer rather than as a failure.

import (
	"context"
	"errors"
	"math"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// offsetOf is the byte offset at which needle starts.
func offsetOf(t *testing.T, source, needle string) int {
	t.Helper()
	i := strings.Index(source, needle)
	if i < 0 {
		t.Fatalf("the fixture does not contain %q", needle)
	}
	return i
}

// idAt is the stable ID of the symbol needle starts at.
func idAt(t *testing.T, source, needle string) wgslender.StableID {
	t.Helper()
	id, ok, err := wgslender.StableIDAtOffset(t.Context(), source, offsetOf(t, source, needle))
	if err != nil {
		t.Fatalf("StableIDAtOffset(%q): %v", needle, err)
	}
	if !ok {
		t.Fatalf("StableIDAtOffset(%q): no symbol there", needle)
	}
	return id
}

// textAt is the source a span covers.
func textAt(t *testing.T, source string, s wgslender.Span) string {
	t.Helper()
	if s.Start < 0 || s.End < s.Start || s.End > len(source) {
		t.Fatalf("span %v does not fit a source of %d bytes", s, len(source))
	}
	return source[s.Start:s.End]
}

func TestFindReferences(t *testing.T) {
	t.Parallel()

	// The npm suite's own fixture, kept because its four references to one
	// name are a stronger shape than the demo's two.
	const helpers = `fn helper(x: f32) -> f32 { return x * 2.0; }
fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
@compute @workgroup_size(1) fn main() { let z = helper(3.0); }`

	cases := []struct {
		name   string
		source string
		// needle locates the symbol; its leading identifier is also the text
		// every reference must spell.
		needle string
		ident  string
		want   int
	}{
		{"a function called from two others", helpers, "helper", "helper", 4},
		{"a function called once", demoWGSL, "luminance(color", "luminance", 2},
		{"a module-scope var", demoWGSL, "params: Params", "params", 5},
		{"a parameter", demoWGSL, "color: vec3f", "color", 2},
		{"a struct named by its var and a constructor", demoWGSL, "Params {", "Params", 2},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			refs, err := wgslender.FindReferences(t.Context(), c.source,
				offsetOf(t, c.source, c.needle), wgslender.WithDeclaration)
			if err != nil {
				t.Fatalf("FindReferences: %v", err)
			}
			if len(refs) != c.want {
				t.Errorf("got %d references, want %d: %v", len(refs), c.want, refs)
			}

			writes := 0
			for _, r := range refs {
				if got := textAt(t, c.source, r.Span); got != c.ident {
					t.Errorf("reference at %v spells %q, want %q", r.Span, got, c.ident)
				}
				if r.IsWrite {
					writes++
				}
			}
			if writes != 1 {
				t.Errorf("got %d writes, want exactly 1 (the declaration)", writes)
			}
			if len(refs) > 0 && !refs[0].IsWrite {
				t.Error("the declaration must sort first")
			}
		})
	}
}

// The one flag FindReferences takes, and the only thing it changes.
func TestFindReferencesDeclarationFlag(t *testing.T) {
	t.Parallel()

	offset := offsetOf(t, demoWGSL, "luminance(color")
	with, err := wgslender.FindReferences(t.Context(), demoWGSL, offset, wgslender.WithDeclaration)
	if err != nil {
		t.Fatalf("with the declaration: %v", err)
	}
	without, err := wgslender.FindReferences(t.Context(), demoWGSL, offset, wgslender.WithoutDeclaration)
	if err != nil {
		t.Fatalf("without the declaration: %v", err)
	}

	if len(with) != len(without)+1 {
		t.Fatalf("got %d and %d references, want a difference of exactly one", len(with), len(without))
	}
	if len(without) == 0 {
		t.Fatal("luminance is called at least once")
	}
	for _, r := range without {
		if r.IsWrite {
			t.Errorf("reference at %v is a write, and the only write is the declaration", r.Span)
		}
	}

	// WithDeclaration is the zero value, so a caller who has not thought about
	// the flag gets the fuller answer rather than a silently truncated one.
	zero, err := wgslender.FindReferences(t.Context(), demoWGSL, offset, 0)
	if err != nil {
		t.Fatalf("with the zero value: %v", err)
	}
	if len(zero) != len(with) {
		t.Errorf("the zero Declarations gave %d references, want the %d of WithDeclaration", len(zero), len(with))
	}
}

// An offset that names nothing is an answer here — no references — where every
// other operation in the family calls it a failure.
func TestFindReferencesFindsNothing(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		offset int
	}{
		{"inside the leading comment", demoWGSL, 0},
		{"one byte past the end", demoWGSL, len(demoWGSL)},
		{"far past the end", demoWGSL, math.MaxUint32},
		{"on whitespace", "const x: f32 = 1.0;", 5},
		{"not WGSL at all", "!!!", 0},
		{"an empty source", "", 0},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			refs, err := wgslender.FindReferences(t.Context(), c.source, c.offset, wgslender.WithDeclaration)
			if err != nil {
				t.Fatalf("FindReferences reported a failure: %v", err)
			}
			if len(refs) != 0 {
				t.Errorf("got %v, want no references", refs)
			}
		})
	}
}

func TestEditOperations(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		call   func(*testing.T, context.Context, string) ([]wgslender.Edit, error)
		check  func(*testing.T, string, []wgslender.Edit)
	}{
		{
			name:   "Rename/rewrites the declaration and every use",
			source: demoWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.Rename(ctx, src, offsetOf(t, src, "luminance(color"), "lum")
			},
			check: func(t *testing.T, src string, edits []wgslender.Edit) {
				if len(edits) != 2 {
					t.Fatalf("got %d edits, want one declaration and one call site", len(edits))
				}
				for _, e := range edits {
					if e.NewText != "lum" {
						t.Errorf("edit at %v inserts %q, want %q", e.Span, e.NewText, "lum")
					}
					if got := textAt(t, src, e.Span); got != "luminance" {
						t.Errorf("edit at %v replaces %q, want %q", e.Span, got, "luminance")
					}
				}
			},
		},
		{
			name:   "RenameByID/reaches the symbol the offset form reaches",
			source: demoWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.RenameByID(ctx, src, idAt(t, src, "luminance(color"), "lum")
			},
			check: func(t *testing.T, src string, byID []wgslender.Edit) {
				byOffset, err := wgslender.Rename(t.Context(), src, offsetOf(t, src, "luminance(color"), "lum")
				if err != nil {
					t.Fatalf("the offset form failed: %v", err)
				}
				if len(byID) != len(byOffset) {
					t.Fatalf("got %d edits by ID and %d by offset", len(byID), len(byOffset))
				}
				for i := range byID {
					if byID[i] != byOffset[i] {
						t.Errorf("edit %d: by ID %v, by offset %v", i, byID[i], byOffset[i])
					}
				}
			},
		},
		{
			name:   "ChangeType/replaces the annotation and nothing else",
			source: annotatedWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.ChangeType(ctx, src, idAt(t, src, "x: f32"), "vec2f")
			},
			check: func(t *testing.T, src string, edits []wgslender.Edit) {
				if len(edits) != 1 {
					t.Fatalf("got %d edits, want exactly one", len(edits))
				}
				if edits[0].NewText != "vec2f" {
					t.Errorf("inserts %q, want %q", edits[0].NewText, "vec2f")
				}
				if got := textAt(t, src, edits[0].Span); got != "f32" {
					t.Errorf("replaces %q, want the annotation alone", got)
				}
			},
		},
		{
			name:   "ChangeType/on a function reaches its return type",
			source: demoWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.ChangeType(ctx, src, idAt(t, src, "luminance(color"), "f16")
			},
			check: func(t *testing.T, src string, edits []wgslender.Edit) {
				if len(edits) != 1 {
					t.Fatalf("got %d edits, want exactly one", len(edits))
				}
				if got := textAt(t, src, edits[0].Span); got != "f32" {
					t.Errorf("replaces %q, want luminance's return type", got)
				}
			},
		},
		{
			name:   "RemoveDeclaration/covers the whole declaration",
			source: demoWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.RemoveDeclaration(ctx, src, idAt(t, src, "luminance(color"))
			},
			check: func(t *testing.T, src string, edits []wgslender.Edit) {
				if len(edits) != 1 {
					t.Fatalf("got %d edits, want exactly one", len(edits))
				}
				if edits[0].NewText != "" {
					t.Errorf("a removal inserts %q, want nothing", edits[0].NewText)
				}
				removed := textAt(t, src, edits[0].Span)
				if !strings.HasPrefix(removed, "fn luminance(") {
					t.Errorf("removes %q, which does not start at the declaration", removed)
				}
				if !strings.HasSuffix(removed, "}") {
					t.Errorf("removes %q, which does not reach the closing brace", removed)
				}
			},
		},
		{
			name:   "RemoveDeclaration/of a local let",
			source: annotatedWGSL,
			call: func(t *testing.T, ctx context.Context, src string) ([]wgslender.Edit, error) {
				return wgslender.RemoveDeclaration(ctx, src, idAt(t, src, "x: f32"))
			},
			check: func(t *testing.T, src string, edits []wgslender.Edit) {
				if len(edits) != 1 {
					t.Fatalf("got %d edits, want exactly one", len(edits))
				}
				if got := textAt(t, src, edits[0].Span); got != "let x: f32 = 1.0;" {
					t.Errorf("removes %q, want the whole statement", got)
				}
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			edits, err := c.call(t, t.Context(), c.source)
			if err != nil {
				t.Fatalf("the operation failed: %v", err)
			}
			c.check(t, c.source, edits)
		})
	}
}

func TestAppliedOperations(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		call   func(*testing.T, context.Context, string) (wgslender.Applied, error)
		check  func(*testing.T, string, wgslender.Applied)
	}{
		{
			name:   "RenameApply/rewrites both sites",
			source: demoWGSL,
			call: func(t *testing.T, ctx context.Context, src string) (wgslender.Applied, error) {
				return wgslender.RenameApply(ctx, src, offsetOf(t, src, "luminance(color"), "lum")
			},
			check: func(t *testing.T, _ string, a wgslender.Applied) {
				if len(a.Edits) != 2 {
					t.Errorf("got %d edits, want two", len(a.Edits))
				}
				for _, want := range []string{"fn lum(", "= lum("} {
					if !strings.Contains(a.Source, want) {
						t.Errorf("the rewritten source does not contain %q", want)
					}
				}
				if strings.Contains(a.Source, "luminance") {
					t.Error("a site was left behind")
				}
			},
		},
		{
			name:   "RenameApply/of a local, byte for byte",
			source: "fn compute_total(n: i32) -> i32 { let count = n + 1; return count * 2; }",
			call: func(t *testing.T, ctx context.Context, src string) (wgslender.Applied, error) {
				return wgslender.RenameApply(ctx, src, offsetOf(t, src, "count"), "items")
			},
			check: func(t *testing.T, _ string, a wgslender.Applied) {
				const want = "fn compute_total(n: i32) -> i32 { let items = n + 1; return items * 2; }"
				if a.Source != want {
					t.Errorf("got  %q\nwant %q", a.Source, want)
				}
			},
		},
		{
			name:   "ChangeTypeApply/rewrites a struct member",
			source: "struct S { x: f32, y: f32 }",
			call: func(t *testing.T, ctx context.Context, src string) (wgslender.Applied, error) {
				return wgslender.ChangeTypeApply(ctx, src, "v1:struct:S/member:x", "i32")
			},
			check: func(t *testing.T, _ string, a wgslender.Applied) {
				const want = "struct S { x: i32, y: f32 }"
				if a.Source != want {
					t.Errorf("got  %q\nwant %q", a.Source, want)
				}
			},
		},
		{
			name:   "ChangeTypeApply/rewrites a parameter",
			source: "fn f(x: f32) -> f32 { return x; }",
			call: func(t *testing.T, ctx context.Context, src string) (wgslender.Applied, error) {
				return wgslender.ChangeTypeApply(ctx, src, "v1:fn:f/param:x", "i32")
			},
			check: func(t *testing.T, _ string, a wgslender.Applied) {
				const want = "fn f(x: i32) -> f32 { return x; }"
				if a.Source != want {
					t.Errorf("got  %q\nwant %q", a.Source, want)
				}
			},
		},
		{
			name:   "RemoveDeclarationApply/takes the declaration out",
			source: "fn helper() -> f32 { return 1.0; }\n@compute @workgroup_size(1) fn main() { let v = helper(); }",
			call: func(t *testing.T, ctx context.Context, src string) (wgslender.Applied, error) {
				return wgslender.RemoveDeclarationApply(ctx, src, "v1:fn:helper")
			},
			check: func(t *testing.T, _ string, a wgslender.Applied) {
				if strings.Contains(a.Source, "fn helper") {
					t.Errorf("the declaration is still there: %q", a.Source)
				}
				if len(a.Edits) != 1 || a.Edits[0].NewText != "" {
					t.Errorf("got %v, want one deletion", a.Edits)
				}
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			applied, err := c.call(t, t.Context(), c.source)
			if err != nil {
				t.Fatalf("the operation failed: %v", err)
			}
			c.check(t, c.source, applied)
		})
	}
}

// Renaming can be iterated: the source that comes out goes back in, and the
// offsets that come out belong to it rather than to what went in.
func TestRenameApplyIterates(t *testing.T) {
	t.Parallel()

	source := `fn step(x: f32) -> f32 { return x + 1.0; }
@compute @workgroup_size(1) fn main() { let a = step(1.0); let b = step(a); }`

	first, err := wgslender.RenameApply(t.Context(), source, offsetOf(t, source, "step"), "advance")
	if err != nil {
		t.Fatalf("renaming the function: %v", err)
	}
	second, err := wgslender.RenameApply(t.Context(), first.Source,
		offsetOf(t, first.Source, "a = advance"), "first")
	if err != nil {
		t.Fatalf("renaming the local: %v", err)
	}

	for _, want := range []string{"fn advance(", "let first = advance(1.0)", "let b = advance(first)"} {
		if !strings.Contains(second.Source, want) {
			t.Errorf("the twice-rewritten source does not contain %q:\n%s", want, second.Source)
		}
	}

	// Two rewrites at byte offsets is exactly where a splice would go wrong
	// quietly, so the result is type-checked rather than merely inspected.
	v, err := wgslender.Validate(t.Context(), second.Source, wgslender.DefaultStrictness)
	if err != nil {
		t.Fatalf("validating the result: %v", err)
	}
	if !v.Valid {
		t.Errorf("the rewritten source no longer validates: %v", v.Diagnostics)
	}
}

// Pinned because it is the opposite of what the name suggests: the declaration
// goes, the calls to it stay, and what comes back does not compile.
func TestRemoveDeclarationLeavesCallSitesDangling(t *testing.T) {
	t.Parallel()

	applied, err := wgslender.RemoveDeclarationApply(t.Context(), demoWGSL, idAt(t, demoWGSL, "luminance(color"))
	if err != nil {
		t.Fatalf("RemoveDeclarationApply: %v", err)
	}
	if strings.Contains(applied.Source, "fn luminance(") {
		t.Error("the declaration is still there")
	}
	if !strings.Contains(applied.Source, "luminance(sampled") {
		t.Error("the call site was removed too, which this test exists to deny")
	}

	v, err := wgslender.Validate(t.Context(), applied.Source, wgslender.DefaultStrictness)
	if err != nil {
		t.Fatalf("validating the result: %v", err)
	}
	if v.Valid {
		t.Error("a call to a function that no longer exists must not validate")
	}
}

// Pinned because it is surprising: the replacement is spliced in verbatim, so
// producing WGSL that means anything is the caller's job.
func TestChangeTypeDoesNotCheckTheReplacement(t *testing.T) {
	t.Parallel()

	applied, err := wgslender.ChangeTypeApply(t.Context(), annotatedWGSL,
		idAt(t, annotatedWGSL, "x: f32"), "not a type")
	if err != nil {
		t.Fatalf("ChangeTypeApply rejected a replacement it is documented to accept: %v", err)
	}
	if !strings.Contains(applied.Source, "let x: not a type = 1.0;") {
		t.Errorf("the replacement was not spliced in verbatim:\n%s", applied.Source)
	}
}

func TestStableIDAtOffset(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		needle string
		want   wgslender.StableID
	}{
		{"a function", demoWGSL, "luminance(color", "v1:fn:luminance"},
		{"a call site, naming the same function", demoWGSL, "luminance(sampled", "v1:fn:luminance"},
		{"an entry point", demoWGSL, "main(@builtin", "v1:fn:main"},
		{"a parameter", demoWGSL, "color: vec3f", "v1:fn:luminance/param:color"},
		{"a let in a function body", demoWGSL, "uv = vec2f", "v1:fn:main/block#0/let:uv"},
		{"a module-scope var", demoWGSL, "params: Params", "v1:var:params"},
		{"a struct", demoWGSL, "Params {", "v1:struct:Params"},
		{"an override", overridesWGSL, "grid: u32", "v1:override:grid"},
		{"an override with an @id", overridesWGSL, "scale: f32", "v1:override:scale"},
		{"a type alias", overridesWGSL, "Index = u32", "v1:alias:Index"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			id, ok, err := wgslender.StableIDAtOffset(t.Context(), c.source, offsetOf(t, c.source, c.needle))
			if err != nil {
				t.Fatalf("StableIDAtOffset: %v", err)
			}
			if !ok {
				t.Fatalf("no symbol at %q", c.needle)
			}
			if id != c.want {
				t.Errorf("got %q, want %q", id, c.want)
			}
		})
	}
}

func TestStableIDAtOffsetFindsNothing(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		offset int
	}{
		{"inside the leading comment", demoWGSL, 0},
		{"far past the end", demoWGSL, math.MaxUint32},
		{"a source the parser only complains about", unparseableWGSL, 0},
		{"not WGSL at all", "!!!", 0},
		{"an empty source", "", 0},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			id, ok, err := wgslender.StableIDAtOffset(t.Context(), c.source, c.offset)
			if err != nil {
				t.Fatalf("StableIDAtOffset reported a failure: %v", err)
			}
			if ok {
				t.Errorf("got %q, want no symbol", id)
			}
		})
	}
}

// A stable ID names a symbol, not a position: it is the same from a use as
// from the declaration, and it still resolves after an edit somewhere else —
// which is the entire reason the family exists.
func TestStableIDSurvivesAnEdit(t *testing.T) {
	t.Parallel()

	fromDeclaration := idAt(t, demoWGSL, "luminance(color")
	if fromUse := idAt(t, demoWGSL, "luminance(sampled"); fromUse != fromDeclaration {
		t.Errorf("the declaration says %q and a use says %q", fromDeclaration, fromUse)
	}

	edited, err := wgslender.RenameApply(t.Context(), demoWGSL, offsetOf(t, demoWGSL, "params: Params"), "p")
	if err != nil {
		t.Fatalf("renaming the uniform: %v", err)
	}
	if !strings.Contains(edited.Source, "var<uniform> p: Params") {
		t.Fatalf("the unrelated edit did not happen:\n%s", edited.Source)
	}

	span, ok, err := wgslender.LocateStableID(t.Context(), edited.Source, fromDeclaration)
	if err != nil {
		t.Fatalf("LocateStableID: %v", err)
	}
	if !ok {
		t.Fatal("the ID stopped resolving after an edit elsewhere")
	}
	if got := textAt(t, edited.Source, span); got != "luminance" {
		t.Errorf("the ID now points at %q", got)
	}
}

// A comment prepended to the file moves every byte offset and no stable ID.
func TestStableIDIgnoresLeadingText(t *testing.T) {
	t.Parallel()

	const source = `fn compute(x: f32) -> f32 { let y = x + 1.0; return y; }`
	const shifted = "// a comment\n" + source

	before := idAt(t, source, "y =")
	after := idAt(t, shifted, "y =")
	if before != after {
		t.Errorf("got %q before the edit and %q after", before, after)
	}
	if before != "v1:fn:compute/block#0/let:y" {
		t.Errorf("got %q, want the block-scoped form", before)
	}
}

func TestLocate(t *testing.T) {
	t.Parallel()

	const helper = "fn helper() -> f32 { return 1.0; }\n@compute @workgroup_size(1) fn main() { let v = helper(); }"

	cases := []struct {
		name   string
		source string
		call   func(context.Context, string) (wgslender.Span, bool, error)
		check  func(*testing.T, string, wgslender.Span)
	}{
		{
			name:   "LocateStableID/the name alone",
			source: helper,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateStableID(ctx, src, "v1:fn:helper")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "helper" {
					t.Errorf("got %q, want the name alone", got)
				}
			},
		},
		{
			name:   "LocateDeclaration/the whole function",
			source: helper,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateDeclaration(ctx, src, "v1:fn:helper")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "fn helper() -> f32 { return 1.0; }" {
					t.Errorf("got %q, want the whole declaration", got)
				}
			},
		},
		{
			name:   "LocateType/a function's return type",
			source: helper,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateType(ctx, src, "v1:fn:helper")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "f32" {
					t.Errorf("got %q, want the return type", got)
				}
			},
		},
		{
			name:   "LocateType/a struct member's type",
			source: "struct S { x: f32, y: f32 }",
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateType(ctx, src, "v1:struct:S/member:x")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "f32" {
					t.Errorf("got %q, want the member's type", got)
				}
			},
		},
		{
			name:   "LocateType/a parameter's type",
			source: "fn f(x: f32) -> f32 { return x; }",
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateType(ctx, src, "v1:fn:f/param:x")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "f32" {
					t.Errorf("got %q, want the parameter's type", got)
				}
			},
		},
		{
			name:   "LocateDeclaration/a local let",
			source: annotatedWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateDeclaration(ctx, src, "v1:fn:main/block#0/let:x")
			},
			check: func(t *testing.T, src string, s wgslender.Span) {
				if got := textAt(t, src, s); got != "let x: f32 = 1.0;" {
					t.Errorf("got %q, want the whole statement", got)
				}
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			span, ok, err := c.call(t.Context(), c.source)
			if err != nil {
				t.Fatalf("locating failed: %v", err)
			}
			if !ok {
				t.Fatal("the ID did not resolve")
			}
			c.check(t, c.source, span)
		})
	}
}

// Absence is an answer, not a failure — the question was answerable and the
// answer is no. Every row here returns ok false and a nil error.
func TestLocateFindsNothing(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		source string
		call   func(context.Context, string) (wgslender.Span, bool, error)
	}{
		{
			name:   "an ID this source does not contain",
			source: demoWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateStableID(ctx, src, "v1:fn:no_such_helper")
			},
		},
		{
			name:   "an ID from a version this engine does not speak",
			source: demoWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateStableID(ctx, src, "v2:fn:luminance")
			},
		},
		{
			name:   "an empty ID",
			source: demoWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateStableID(ctx, src, "")
			},
		},
		{
			// Producing an ID this long fails with ErrStableIDTooLong; looking
			// one up merely does not find it.
			name:   "an ID longer than the engine will ever produce",
			source: demoWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateStableID(ctx, src, wgslender.StableID("v1:fn:"+strings.Repeat("a", 5000)))
			},
		},
		{
			name:   "a symbol with no type to point at",
			source: demoWGSL,
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateType(ctx, src, "v1:fn:main")
			},
		},
		{
			// LocateStableID and LocateType both resolve a member; this one
			// does not, which is a seam rather than a rule.
			name:   "the declaration of a struct member",
			source: "struct S { x: f32, y: f32 }",
			call: func(ctx context.Context, src string) (wgslender.Span, bool, error) {
				return wgslender.LocateDeclaration(ctx, src, "v1:struct:S/member:x")
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			span, ok, err := c.call(t.Context(), c.source)
			if err != nil {
				t.Fatalf("absence must not be an error: %v", err)
			}
			if ok {
				t.Errorf("got %v, want no answer", span)
			}
			if span != (wgslender.Span{}) {
				t.Errorf("got %v alongside ok false, want the zero span", span)
			}
		})
	}
}

// Every wire failure the engine can name, provoked through the operation that
// reaches it, and mapped to the sentinel a caller compares against.
func TestRefactorErrors(t *testing.T) {
	t.Parallel()

	longName := "fn a" + strings.Repeat("a", 5000) + "() { let x = 1; }"

	cases := []struct {
		name string
		call func(*testing.T, context.Context) error
		want error
	}{
		{
			name: "the parser gave up",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.Rename(ctx, unrecoverableWGSL, 3, "g")
				return err
			},
			want: wgslender.ErrParse,
		},
		{
			name: "the parser gave up, by ID",
			call: func(t *testing.T, ctx context.Context) error {
				_, _, err := wgslender.LocateStableID(ctx, unrecoverableWGSL, "v1:fn:f")
				return err
			},
			want: wgslender.ErrParse,
		},
		{
			name: "nothing under the offset",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.Rename(ctx, "// just a comment\n", 0, "x")
				return err
			},
			want: wgslender.ErrSymbolNotFound,
		},
		{
			name: "an ID nothing declares",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.RemoveDeclaration(ctx, demoWGSL, "v1:fn:no_such_helper")
				return err
			},
			want: wgslender.ErrSymbolNotFound,
		},
		{
			name: "a keyword is not a name",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.Rename(ctx, demoWGSL, offsetOf(t, demoWGSL, "luminance(color"), "fn")
				return err
			},
			want: wgslender.ErrInvalidIdentifier,
		},
		{
			name: "an empty new name",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.RenameApply(ctx, demoWGSL, offsetOf(t, demoWGSL, "luminance(color"), "")
				return err
			},
			want: wgslender.ErrInvalidIdentifier,
		},
		{
			name: "an inferred let has no annotation to replace",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.ChangeType(ctx, demoWGSL, "v1:fn:main/block#0/let:uv", "vec2f")
				return err
			},
			want: wgslender.ErrNoTypeAnnotation,
		},
		{
			name: "an entry point has no return type to replace",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.ChangeTypeApply(ctx, annotatedWGSL, "v1:fn:main", "vec2f")
				return err
			},
			want: wgslender.ErrNoTypeAnnotation,
		},
		{
			name: "a struct member is not removable on its own",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.RemoveDeclaration(ctx, demoWGSL, "v1:struct:Params/member:time")
				return err
			},
			want: wgslender.ErrNotRemovable,
		},
		{
			name: "neither is a parameter",
			call: func(t *testing.T, ctx context.Context) error {
				_, err := wgslender.RemoveDeclarationApply(ctx, demoWGSL, "v1:fn:luminance/param:color")
				return err
			},
			want: wgslender.ErrNotRemovable,
		},
		{
			name: "the ID would be longer than the engine will build",
			call: func(t *testing.T, ctx context.Context) error {
				_, _, err := wgslender.StableIDAtOffset(ctx, longName, offsetOf(t, longName, "x ="))
				return err
			},
			want: wgslender.ErrStableIDTooLong,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			err := c.call(t, t.Context())
			if !errors.Is(err, c.want) {
				t.Fatalf("got %v, want %v", err, c.want)
			}
		})
	}
}

// The wire hands the original source back when an apply fails. The caller
// already has it, so the failure is reported instead of echoed.
func TestApplyFailureDoesNotEchoTheSource(t *testing.T) {
	t.Parallel()

	const source = "const v: i32 = 0;"
	applied, err := wgslender.RenameApply(t.Context(), source, offsetOf(t, source, "v"), "return")
	if !errors.Is(err, wgslender.ErrInvalidIdentifier) {
		t.Fatalf("got %v, want ErrInvalidIdentifier", err)
	}
	if applied.Source != "" || applied.Edits != nil {
		t.Errorf("got %v alongside the error, want the zero Applied", applied)
	}
}

// Offsets are UTF-8 byte offsets on the way in and on the way back, which only
// a fixture with multi-byte runes can tell apart from rune offsets.
func TestOffsetsAreBytes(t *testing.T) {
	t.Parallel()

	byteOffset := offsetOf(t, multibyteWGSL, "héllo(x: f32)")
	if runeOffset := utf8.RuneCountInString(multibyteWGSL[:byteOffset]); runeOffset == byteOffset {
		t.Fatal("the fixture has no multi-byte rune before the declaration, so this test proves nothing")
	}

	refs, err := wgslender.FindReferences(t.Context(), multibyteWGSL, byteOffset, wgslender.WithDeclaration)
	if err != nil {
		t.Fatalf("FindReferences: %v", err)
	}
	if len(refs) != 2 {
		t.Fatalf("got %d references, want the declaration and one call", len(refs))
	}
	if refs[0].Start != byteOffset {
		t.Errorf("the declaration starts at %d, want the byte offset %d", refs[0].Start, byteOffset)
	}
	for _, r := range refs {
		if got := textAt(t, multibyteWGSL, r.Span); got != "héllo" {
			t.Errorf("reference at %v spells %q", r.Span, got)
		}
		// héllo is five runes and six bytes; a span measured in runes would
		// stop one byte short and cut the é in half.
		if n := r.End - r.Start; n != len("héllo") {
			t.Errorf("reference at %v is %d bytes long, want %d", r.Span, n, len("héllo"))
		}
	}
}

// Renaming a multi-byte identifier is a splice at byte offsets, so a rewrite
// that got them wrong would hand back text that is no longer UTF-8.
func TestRenameApplyKeepsTextValid(t *testing.T) {
	t.Parallel()

	applied, err := wgslender.RenameApply(t.Context(), multibyteWGSL,
		offsetOf(t, multibyteWGSL, "héllo(x: f32)"), "world")
	if err != nil {
		t.Fatalf("RenameApply: %v", err)
	}
	if !utf8.ValidString(applied.Source) {
		t.Fatal("the rewritten source is not valid UTF-8")
	}
	if strings.Contains(applied.Source, "héllo") {
		t.Error("a site was left behind")
	}
	if n := strings.Count(applied.Source, "world"); n != 2 {
		t.Errorf("got %d occurrences of the new name, want 2", n)
	}
	if !strings.Contains(applied.Source, "// 🎨🎨 a comment") {
		t.Error("the leading comment's runes did not survive")
	}

	v, err := wgslender.Validate(t.Context(), applied.Source, wgslender.DefaultStrictness)
	if err != nil {
		t.Fatalf("validating the result: %v", err)
	}
	if !v.Valid {
		t.Errorf("the rewritten source no longer validates: %v", v.Diagnostics)
	}
}

// The engine reads identifiers WGSL's way — any XID_Start rune opens one — and
// writes them a narrower way. It will happily find and rename héllo, and it
// will not rename anything *to* wörld.
//
// So this is not a rule about WGSL, which accepts both. It is a rule about the
// renamer, and the only way to find it is to try.
func TestRenameRefusesNonASCIINames(t *testing.T) {
	t.Parallel()

	// The existing non-ASCII name is no obstacle: it is the new one that is
	// judged.
	if _, err := wgslender.Rename(t.Context(), multibyteWGSL,
		offsetOf(t, multibyteWGSL, "héllo(x: f32)"), "world"); err != nil {
		t.Fatalf("renaming a non-ASCII symbol to an ASCII name: %v", err)
	}

	for _, name := range []string{"wörld", "héllo", "日本語"} {
		if _, err := wgslender.Rename(t.Context(), demoWGSL,
			offsetOf(t, demoWGSL, "luminance(color"), name); !errors.Is(err, wgslender.ErrInvalidIdentifier) {
			t.Errorf("renaming to %q gave %v, want ErrInvalidIdentifier", name, err)
		}
	}
}

// The reflection block hands out stable IDs for struct members, and they work
// — but the offset form will not give you one, which is worth knowing before
// building an editor around it.
func TestStableIDAtOffsetDoesNotReachStructMembers(t *testing.T) {
	t.Parallel()

	r, err := wgslender.Reflect(t.Context(), demoWGSL)
	if err != nil {
		t.Fatalf("Reflect: %v", err)
	}
	layout, ok := r.Structs["Params"]
	if !ok || len(layout.Fields) == 0 {
		t.Fatal("the demo fixture declares Params with members")
	}
	id := layout.Fields[0].StableID
	if id != "v1:struct:Params/member:resolution" {
		t.Fatalf("got %q, want the member form", id)
	}

	span, ok, err := wgslender.LocateStableID(t.Context(), demoWGSL, id)
	if err != nil {
		t.Fatalf("LocateStableID: %v", err)
	}
	if !ok {
		t.Fatal("a member ID from Reflect must resolve")
	}
	if got := textAt(t, demoWGSL, span); got != "resolution" {
		t.Errorf("the member ID points at %q", got)
	}

	// The same member, reached by offset instead.
	_, ok, err = wgslender.StableIDAtOffset(t.Context(), demoWGSL, offsetOf(t, demoWGSL, "resolution: vec2f"))
	if err != nil {
		t.Fatalf("StableIDAtOffset: %v", err)
	}
	if ok {
		t.Error("StableIDAtOffset now reaches struct members; the asymmetry this test records is gone")
	}
}

func TestRefactorRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	// A lone continuation byte: never a valid UTF-8 sequence on its own.
	const bad = "\x80"

	cases := []struct {
		name string
		call func(context.Context, string) error
	}{
		{"FindReferences/source", func(ctx context.Context, s string) error {
			_, err := wgslender.FindReferences(ctx, s, 0, wgslender.WithDeclaration)
			return err
		}},
		{"Rename/source", func(ctx context.Context, s string) error {
			_, err := wgslender.Rename(ctx, s, 0, "x")
			return err
		}},
		{"Rename/new name", func(ctx context.Context, s string) error {
			_, err := wgslender.Rename(ctx, demoWGSL, 0, s)
			return err
		}},
		{"RenameApply/new name", func(ctx context.Context, s string) error {
			_, err := wgslender.RenameApply(ctx, demoWGSL, 0, s)
			return err
		}},
		{"StableIDAtOffset/source", func(ctx context.Context, s string) error {
			_, _, err := wgslender.StableIDAtOffset(ctx, s, 0)
			return err
		}},
		{"LocateStableID/id", func(ctx context.Context, s string) error {
			_, _, err := wgslender.LocateStableID(ctx, demoWGSL, wgslender.StableID(s))
			return err
		}},
		{"LocateDeclaration/id", func(ctx context.Context, s string) error {
			_, _, err := wgslender.LocateDeclaration(ctx, demoWGSL, wgslender.StableID(s))
			return err
		}},
		{"LocateType/source", func(ctx context.Context, s string) error {
			_, _, err := wgslender.LocateType(ctx, s, "v1:fn:main")
			return err
		}},
		{"RenameByID/new name", func(ctx context.Context, s string) error {
			_, err := wgslender.RenameByID(ctx, demoWGSL, "v1:fn:luminance", s)
			return err
		}},
		{"RemoveDeclaration/id", func(ctx context.Context, s string) error {
			_, err := wgslender.RemoveDeclaration(ctx, demoWGSL, wgslender.StableID(s))
			return err
		}},
		{"RemoveDeclarationApply/source", func(ctx context.Context, s string) error {
			_, err := wgslender.RemoveDeclarationApply(ctx, s, "v1:fn:luminance")
			return err
		}},
		{"ChangeType/new type", func(ctx context.Context, s string) error {
			_, err := wgslender.ChangeType(ctx, annotatedWGSL, "v1:fn:main/block#0/let:x", s)
			return err
		}},
		{"ChangeTypeApply/new type", func(ctx context.Context, s string) error {
			_, err := wgslender.ChangeTypeApply(ctx, annotatedWGSL, "v1:fn:main/block#0/let:x", s)
			return err
		}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			if err := c.call(t.Context(), bad); !errors.Is(err, wgslender.ErrInvalidUTF8) {
				t.Errorf("got %v, want ErrInvalidUTF8", err)
			}
		})
	}
}

// An offset the ABI cannot carry is refused rather than truncated into one
// that names a different symbol.
func TestRefactorRejectsUnsendableOffsets(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		offset int
	}{
		{"negative", -1},
		{"very negative", math.MinInt},
		{"beyond a u32", math.MaxUint32 + 1},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			if _, err := wgslender.FindReferences(t.Context(), demoWGSL, c.offset, wgslender.WithDeclaration); !errors.Is(err, wgslender.ErrInvalidOffset) {
				t.Errorf("FindReferences: got %v, want ErrInvalidOffset", err)
			}
			if _, err := wgslender.Rename(t.Context(), demoWGSL, c.offset, "x"); !errors.Is(err, wgslender.ErrInvalidOffset) {
				t.Errorf("Rename: got %v, want ErrInvalidOffset", err)
			}
			if _, _, err := wgslender.StableIDAtOffset(t.Context(), demoWGSL, c.offset); !errors.Is(err, wgslender.ErrInvalidOffset) {
				t.Errorf("StableIDAtOffset: got %v, want ErrInvalidOffset", err)
			}
		})
	}
}
