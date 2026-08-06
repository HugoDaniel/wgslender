package wgslender

// The wire-string to sentinel map, tested from inside the package.
//
// Every string here is also provoked through a real call in
// TestRefactorErrors, which is the test that proves the engine still spells
// them this way. This one exists for the row that no shader can produce: a
// reason this package has never heard of, which must survive as an error
// rather than be dropped or mistaken for one of the known ones.

import (
	"errors"
	"strings"
	"testing"
)

func TestRefactorError(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		reason string
		want   error
	}{
		{"nothing went wrong", "", nil},
		{"the parser gave up", "parse error", ErrParse},
		{"no symbol there", "symbol not found", ErrSymbolNotFound},
		{"not a name", "invalid identifier", ErrInvalidIdentifier},
		{"nothing to retype", "no type annotation or invalid replacement", ErrNoTypeAnnotation},
		{"nothing to remove", "not a removable declaration", ErrNotRemovable},
		{"the ID does not fit", "id too long", ErrStableIDTooLong},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			err := refactorError(c.reason)
			if !errors.Is(err, c.want) {
				t.Fatalf("refactorError(%q) = %v, want %v", c.reason, err, c.want)
			}
			if c.want != nil && !strings.Contains(err.Error(), c.reason) {
				t.Errorf("refactorError(%q) prints as %q, which does not carry the engine's own words", c.reason, err)
			}
		})
	}
}

// A reason from a newer engine than this package was built against. It cannot
// map to a sentinel, so the requirement is only that it is not silently lost.
func TestRefactorErrorKeepsWhatItCannotName(t *testing.T) {
	t.Parallel()

	const reason = "the flux capacitor is misaligned"
	err := refactorError(reason)
	if err == nil {
		t.Fatal("an unrecognised reason must still be an error")
	}
	if !strings.Contains(err.Error(), reason) {
		t.Errorf("got %q, which does not carry the engine's own words", err)
	}
	for _, sentinel := range []error{
		ErrParse, ErrSymbolNotFound, ErrInvalidIdentifier,
		ErrNoTypeAnnotation, ErrNotRemovable, ErrStableIDTooLong,
	} {
		if errors.Is(err, sentinel) {
			t.Errorf("an unrecognised reason matched %v", sentinel)
		}
	}
}

// "not found" is the locate family's way of saying the question was
// answerable and the answer is no. It is handled before the map is consulted,
// so reaching the map with it would turn an ordinary absence into a failure.
func TestNotFoundIsNotASentinel(t *testing.T) {
	t.Parallel()

	err := refactorError(notFoundReason)
	if err == nil {
		t.Fatal("the map must not silently swallow a reason it does not know")
	}
	for _, sentinel := range []error{ErrParse, ErrSymbolNotFound, ErrStableIDTooLong} {
		if errors.Is(err, sentinel) {
			t.Errorf("%q maps to %v, and it must map to nothing", notFoundReason, sentinel)
		}
	}
}
