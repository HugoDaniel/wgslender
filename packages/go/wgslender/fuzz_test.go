package wgslender_test

import (
	"errors"
	"testing"
	"unicode/utf8"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// FuzzEveryCall drives the rest of the public surface with one arbitrary
// string and one arbitrary offset, asserting the boundary FuzzMinify pins for
// Minify alone: valid UTF-8 is answered — no shader is bad enough to be a Go
// error from Validate, Reflect or Lint — and invalid UTF-8 is refused by
// name, before anything else gets a say. FindReferences stands in for the
// refactor family, whose refusals are documented sentinels; an error outside
// that list would be a new behaviour nobody wrote down.
func FuzzEveryCall(f *testing.F) {
	for _, seed := range []string{
		demoWGSL,
		invalidWGSL,
		unparseableWGSL,
		"",
		"😀",
		"let\x95",
	} {
		f.Add(seed, 0)
		f.Add(seed, len(seed)/2)
	}
	f.Add(demoWGSL, -1)
	f.Add(demoWGSL, 1<<40)

	f.Fuzz(func(t *testing.T, source string, offset int) {
		ctx := t.Context()
		valid := utf8.ValidString(source)

		answered := func(call string, err error) {
			t.Helper()
			if !valid {
				if !errors.Is(err, wgslender.ErrInvalidUTF8) {
					t.Fatalf("%s(%q) = %v, want ErrInvalidUTF8", call, source, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("%s(%q) = %v, want an answer", call, source, err)
			}
		}

		_, err := wgslender.Validate(ctx, source, wgslender.DefaultStrictness)
		answered("Validate", err)
		_, err = wgslender.Reflect(ctx, source)
		answered("Reflect", err)
		_, err = wgslender.Lint(ctx, source, &wgslender.LintConfig{
			Extends: []wgslender.Pack{wgslender.PackRecommended},
		})
		answered("Lint", err)

		_, err = wgslender.FindReferences(ctx, source, offset, wgslender.WithDeclaration)
		switch {
		case !valid:
			// The UTF-8 check runs before the offset check, so a bad offset
			// does not change the answer for bad bytes.
			if !errors.Is(err, wgslender.ErrInvalidUTF8) {
				t.Fatalf("FindReferences(%q, %d) = %v, want ErrInvalidUTF8", source, offset, err)
			}
		case err == nil:
		case errors.Is(err, wgslender.ErrInvalidOffset):
		case errors.Is(err, wgslender.ErrParse):
		default:
			t.Fatalf("FindReferences(%q, %d) = %v, which is none of the documented refusals",
				source, offset, err)
		}
	})
}
