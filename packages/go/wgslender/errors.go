package wgslender

import (
	"errors"
	"fmt"
	"unicode/utf8"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
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
)

// checkUTF8 rejects an argument that is not valid UTF-8, naming which one it
// was.
func checkUTF8(name, s string) error {
	if utf8.ValidString(s) {
		return nil
	}
	return fmt.Errorf("%w: %s", ErrInvalidUTF8, name)
}
