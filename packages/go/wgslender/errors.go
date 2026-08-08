package wgslender

import (
	"errors"
	"fmt"
	"unicode/utf8"

	"github.com/HugoDaniel/wgslender/packages/go/internal/wasmabi"
)

// The errors this package reports for a call that could not be made or could
// not be believed. A shader's own problems are never one of these: they arrive
// as data — [MinifyResult.Errors], [Validation.Diagnostics] and their kin.
var (
	// ErrInternal reports that the engine failed for a reason it cannot
	// describe: it ran out of memory, or a length overflowed its 32-bit
	// address space.
	ErrInternal = wasmabi.ErrInternal

	// ErrSourceTooLarge reports an input larger than the engine's 32-bit
	// address space.
	ErrSourceTooLarge = wasmabi.ErrSourceTooLarge

	// ErrInvalidUTF8 reports an argument that is not valid UTF-8.
	//
	// WGSL is defined over UTF-8 text, and Go's string type does not enforce
	// that, so this package checks. It has to: the engine copies unknown bytes
	// through into its JSON replies verbatim, and every JSON decoder then
	// silently substitutes U+FFFD for them — the answer would come back
	// corrupted rather than refused. (Rust gets this from &str for free and
	// the npm package does the substituting.)
	ErrInvalidUTF8 = errors.New("wgslender: not valid UTF-8")

	// ErrInvalidOffset reports a byte offset the ABI cannot carry: a negative
	// one, or one beyond the engine's 32-bit address space.
	//
	// An offset merely past the end of the source is not one of these. The
	// engine answers that nothing is there, which is true and useful, so it is
	// passed through rather than refused.
	ErrInvalidOffset = errors.New("wgslender: offset out of range")
)

// The refactor operations' failures, one for each reason the engine can name.
// A shader's own problems are still data everywhere else in this package;
// these are here because a refactor that cannot be performed has no edits to
// report, and an empty edit list would say the opposite — that there was
// nothing to do.
var (
	// ErrParse reports source the parser abandoned.
	//
	// It is narrower than "invalid WGSL". The parser recovers from most
	// mistakes and hands back a module full of errors, and a refactor over
	// that module answers normally. This is the residue: the shapes it cannot
	// rebuild anything from.
	ErrParse = errors.New("wgslender: the shader could not be parsed")

	// ErrSymbolNotFound reports an offset that names no symbol, or a
	// [StableID] this source does not contain.
	//
	// [FindReferences] is the exception that proves the rule: it answers the
	// same situation with no references at all, because asking it about
	// wherever a cursor happens to be is the normal way to use it.
	ErrSymbolNotFound = errors.New("wgslender: no such symbol")

	// ErrInvalidIdentifier reports a new name WGSL will not accept — a
	// keyword, a reserved word, an empty string, or anything that is not
	// spelled like an identifier.
	ErrInvalidIdentifier = errors.New("wgslender: not a valid WGSL identifier")

	// ErrNoTypeAnnotation reports a symbol with no declared type to replace,
	// such as an inferred let or an entry point that returns nothing.
	// [LocateType] answers the same question without changing anything.
	ErrNoTypeAnnotation = errors.New("wgslender: no type annotation to replace")

	// ErrNotRemovable reports something that is not a declaration in its own
	// right — a struct member, a function parameter — and so cannot be deleted
	// without rewriting what encloses it.
	ErrNotRemovable = errors.New("wgslender: not a removable declaration")

	// ErrStableIDTooLong reports a symbol whose ID would exceed the engine's
	// buffer, which takes a name or a nesting depth in the thousands. Looking
	// up an ID that long is not this error — it simply is not found.
	ErrStableIDTooLong = errors.New("wgslender: the stable ID is too long")
)

// checkUTF8 rejects an argument that is not valid UTF-8, naming which one it
// was.
func checkUTF8(name, s string) error {
	if utf8.ValidString(s) {
		return nil
	}
	return fmt.Errorf("%w: %s", ErrInvalidUTF8, name)
}

// checkEngineUTF8 distrusts text the engine produced that is not valid UTF-8.
// It wraps [ErrInternal], not [ErrInvalidUTF8]: that sentinel tells a caller
// to fix an argument, and every argument was checked on the way in — bytes
// broken on the way out are the engine's splice landing inside a rune.
func checkEngineUTF8(name, s string) error {
	if utf8.ValidString(s) {
		return nil
	}
	return fmt.Errorf("%w: the engine's %s is not valid UTF-8", ErrInternal, name)
}
