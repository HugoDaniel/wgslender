package wgslender

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/HugoDaniel/wgslender/packages/go/internal/wasmabi"
)

// The guest exports behind the twelve refactor operations.
const (
	findReferencesFn         = "wgslender_find_references"
	renameFn                 = "wgslender_rename"
	renameApplyFn            = "wgslender_rename_apply"
	stableIDAtOffsetFn       = "wgslender_stable_id_at_offset"
	locateStableIDFn         = "wgslender_locate_stable_id"
	locateDeclarationFn      = "wgslender_locate_declaration"
	locateTypeFn             = "wgslender_locate_type"
	renameByIDFn             = "wgslender_rename_by_id"
	removeDeclarationFn      = "wgslender_remove_declaration_by_id"
	removeDeclarationApplyFn = "wgslender_remove_declaration_apply_by_id"
	changeTypeFn             = "wgslender_change_type_by_id"
	changeTypeApplyFn        = "wgslender_change_type_apply_by_id"
)

// An Edit is a splice: replace the source in Span with NewText.
//
// Edits within one result never overlap, so they can be applied in any order —
// though applying them from the end backwards is the only order that does not
// invalidate the offsets of the ones still to come. The apply-suffixed
// operations do this for you.
type Edit struct {
	// Span is the half-open byte range to replace.
	Span
	// NewText is what to put there. Empty means a deletion.
	NewText string `json:"newText"`
}

// A Reference is one mention of a symbol.
type Reference struct {
	// Span is the half-open byte range of the identifier, and covers the name
	// alone rather than the expression it appears in.
	Span
	// IsWrite reports whether this mention writes the symbol. The declaration
	// is a write; so is the left-hand side of an assignment.
	IsWrite bool `json:"isWrite"`
}

// An Applied is the result of an operation that performed its own edits.
type Applied struct {
	// Source is the rewritten shader.
	Source string
	// Edits is what was done to produce it, at offsets into the *original*
	// source. They are of no use for splicing — that already happened — and of
	// every use for showing a diff or moving a cursor.
	Edits []Edit
}

// Declarations says whether [FindReferences] counts a symbol's declaration
// among the references to it.
//
// It is a named choice rather than a bool argument, so that the call site says
// which it means. The zero value includes the declaration, which is the fuller
// answer.
type Declarations int

const (
	// WithDeclaration counts the declaration. It sorts first, and it is the
	// one reference whose IsWrite is true in a shader that never assigns to
	// the symbol again.
	WithDeclaration Declarations = iota
	// WithoutDeclaration leaves it out, which is what "find usages" means in
	// most editors.
	WithoutDeclaration
)

// include is the guest's include_declaration argument for this choice. The
// guest tests it against zero, so the mapping has to be explicit: the zero
// Declarations means include, and passing it through as a number would mean
// the opposite.
func (d Declarations) include() uint32 {
	if d == WithoutDeclaration {
		return 0
	}
	return 1
}

// notFoundReason is the locate family's way of saying that the question was
// answerable and the answer is no. It is not a failure and never becomes one:
// every caller checks for it before consulting the sentinel map.
const notFoundReason = "not found"

// refactorError turns the engine's reason into an error, or nil when there is
// no reason. A reason this package has never heard of stays an error carrying
// the engine's own words, because a newer engine adding one must not look like
// success here.
func refactorError(reason string) error {
	switch reason {
	case "":
		return nil
	case "parse error":
		return fmt.Errorf("%w: %s", ErrParse, reason)
	case "symbol not found":
		return fmt.Errorf("%w: %s", ErrSymbolNotFound, reason)
	case "invalid identifier":
		return fmt.Errorf("%w: %s", ErrInvalidIdentifier, reason)
	case "no type annotation or invalid replacement":
		return fmt.Errorf("%w: %s", ErrNoTypeAnnotation, reason)
	case "not a removable declaration":
		return fmt.Errorf("%w: %s", ErrNotRemovable, reason)
	case "id too long":
		return fmt.Errorf("%w: %s", ErrStableIDTooLong, reason)
	default:
		return fmt.Errorf("wgslender: %s", reason)
	}
}

// offsetArg converts a byte offset into the guest's argument, refusing one the
// ABI cannot carry.
//
// An offset past the end of the source is not refused: the engine answers that
// nothing is there, which is the truth and is what the caller wants to hear.
// Only an offset that could not have come from indexing the source at all is a
// caller bug worth reporting.
func offsetArg(offset int) (wasmabi.Arg, error) {
	if offset < 0 || offset > math.MaxUint32 {
		return wasmabi.Arg{}, fmt.Errorf("%w: %d", ErrInvalidOffset, offset)
	}
	return wasmabi.Scalar(uint32(offset)), nil
}

// refactorCall runs one operation and hands back its JSON envelope. Every one
// of the twelve is length-prefixed JSON and nothing else.
func refactorCall(ctx context.Context, fn string, args ...wasmabi.Arg) ([]byte, error) {
	res, err := wasmabi.Call(ctx, fn, wasmabi.PackLenPrefixed, args...)
	if err != nil {
		return nil, err
	}
	return res.Payloads[0], nil
}

// decode unmarshals an envelope, naming the operation in the failure so that a
// wire change is traceable to the export that made it.
func decode(fn string, payload []byte, into any) error {
	if err := json.Unmarshal(payload, into); err != nil {
		return fmt.Errorf("wgslender: decoding the %s envelope: %w", fn, err)
	}
	return nil
}

// FindReferences finds every mention of the symbol at a byte offset.
//
// The result is in source order, so the declaration — when it is included —
// comes first. An offset that names no symbol is not an error here: it comes
// back as no references at all, which lets an editor ask about wherever the
// cursor happens to be without checking first. Every other operation in this
// family calls the same situation [ErrSymbolNotFound].
func FindReferences(ctx context.Context, source string, offset int, d Declarations) ([]Reference, error) {
	if err := checkUTF8("source", source); err != nil {
		return nil, err
	}
	at, err := offsetArg(offset)
	if err != nil {
		return nil, err
	}
	payload, err := refactorCall(ctx, findReferencesFn,
		wasmabi.Text(source), at, wasmabi.Scalar(d.include()))
	if err != nil {
		return nil, err
	}

	var w struct {
		References []Reference `json:"references"`
		Error      string      `json:"error"`
	}
	if err := decode(findReferencesFn, payload, &w); err != nil {
		return nil, err
	}
	if err := refactorError(w.Error); err != nil {
		return nil, err
	}
	return w.References, nil
}

// Rename produces the edits that rename the symbol at a byte offset, without
// applying them. Use [RenameApply] to get the rewritten source instead.
//
// A name WGSL will not accept — a keyword, an empty string, anything that is
// not an identifier — is [ErrInvalidIdentifier], and is refused before the
// shader is even parsed.
//
// So is a name outside ASCII. WGSL opens an identifier with any XID_Start
// rune, and the engine reads such names perfectly well — this operation will
// find and rename héllo — but it will not rename anything *to* wörld. That is
// a limit of the renamer rather than of the language.
func Rename(ctx context.Context, source string, offset int, newName string) ([]Edit, error) {
	if err := checkUTF8("source", source); err != nil {
		return nil, err
	}
	if err := checkUTF8("new name", newName); err != nil {
		return nil, err
	}
	at, err := offsetArg(offset)
	if err != nil {
		return nil, err
	}
	return editsFrom(ctx, renameFn,
		wasmabi.Text(source), at, wasmabi.Text(newName))
}

// RenameApply renames the symbol at a byte offset and returns the rewritten
// source.
//
// What comes back parses, but nothing promises it is correct: renaming a
// symbol to a name already taken in the same scope produces a shader that
// [Validate] will reject. The rewrite is a splice, not a refactoring engine.
func RenameApply(ctx context.Context, source string, offset int, newName string) (Applied, error) {
	if err := checkUTF8("source", source); err != nil {
		return Applied{}, err
	}
	if err := checkUTF8("new name", newName); err != nil {
		return Applied{}, err
	}
	at, err := offsetArg(offset)
	if err != nil {
		return Applied{}, err
	}
	return appliedFrom(ctx, renameApplyFn,
		wasmabi.Text(source), at, wasmabi.Text(newName))
}

// StableIDAtOffset names the symbol at a byte offset in a way that survives
// reparsing.
//
// The false return is for an offset that names no symbol — a comment, an
// operator, past the end of the file — which is an answer and not a failure.
//
// Not everything with an ID has one that can be found this way. A struct
// member's ID works everywhere it is accepted, but only [Reflect] hands it
// out; asking for one at the member's own offset comes back false.
func StableIDAtOffset(ctx context.Context, source string, offset int) (StableID, bool, error) {
	if err := checkUTF8("source", source); err != nil {
		return "", false, err
	}
	at, err := offsetArg(offset)
	if err != nil {
		return "", false, err
	}
	payload, err := refactorCall(ctx, stableIDAtOffsetFn, wasmabi.Text(source), at)
	if err != nil {
		return "", false, err
	}

	var w struct {
		StableID *string `json:"stableId"`
		Error    string  `json:"error"`
	}
	if err := decode(stableIDAtOffsetFn, payload, &w); err != nil {
		return "", false, err
	}
	if err := refactorError(w.Error); err != nil {
		return "", false, err
	}
	if w.StableID == nil {
		return "", false, nil
	}
	return StableID(*w.StableID), true, nil
}

// LocateStableID finds the name a [StableID] refers to.
//
// The span covers the identifier alone. The false return means this source
// does not contain that symbol — it was deleted, or the ID came from a
// different file, or it is in a format this engine does not speak — and is an
// answer rather than a failure.
func LocateStableID(ctx context.Context, source string, id StableID) (Span, bool, error) {
	return locate(ctx, locateStableIDFn, source, id)
}

// LocateDeclaration finds the whole declaration a [StableID] refers to:
// attributes, body, trailing semicolon and all. It is the span to remove, or
// to fold, or to jump to.
//
// A struct member has no declaration of its own in this sense, so it comes
// back false even though [LocateStableID] and [LocateType] both resolve it.
func LocateDeclaration(ctx context.Context, source string, id StableID) (Span, bool, error) {
	return locate(ctx, locateDeclarationFn, source, id)
}

// LocateType finds the type annotation a [StableID] refers to: a function's
// return type, a parameter's or member's declared type, a variable's
// annotation when it has one.
//
// The false return means there is nothing to point at — an entry point with no
// return type, a let whose type is inferred — which is exactly the case
// [ChangeType] reports as [ErrNoTypeAnnotation].
func LocateType(ctx context.Context, source string, id StableID) (Span, bool, error) {
	return locate(ctx, locateTypeFn, source, id)
}

// locate is the body the three locate operations share.
func locate(ctx context.Context, fn, source string, id StableID) (Span, bool, error) {
	if err := checkUTF8("source", source); err != nil {
		return Span{}, false, err
	}
	if err := checkUTF8("stable id", string(id)); err != nil {
		return Span{}, false, err
	}
	payload, err := refactorCall(ctx, fn, wasmabi.Text(source), wasmabi.Text(string(id)))
	if err != nil {
		return Span{}, false, err
	}

	var w struct {
		Start *int   `json:"start"`
		End   *int   `json:"end"`
		Error string `json:"error"`
	}
	if err := decode(fn, payload, &w); err != nil {
		return Span{}, false, err
	}
	// Absence arrives as a reason, alongside the reasons that are real
	// failures, and is separated here rather than in refactorError so that the
	// map stays a map of failures.
	if w.Error == notFoundReason {
		return Span{}, false, nil
	}
	if err := refactorError(w.Error); err != nil {
		return Span{}, false, err
	}
	if w.Start == nil || w.End == nil {
		return Span{}, false, nil
	}
	return Span{Start: *w.Start, End: *w.End}, true, nil
}

// RenameByID renames the symbol a [StableID] refers to, producing the same
// edits [Rename] would produce from an offset on that symbol.
//
// The difference is when the ID was obtained: an offset taken before an
// unrelated edit points somewhere else afterwards, and an ID does not.
func RenameByID(ctx context.Context, source string, id StableID, newName string) ([]Edit, error) {
	if err := checkUTF8("new name", newName); err != nil {
		return nil, err
	}
	return editsByID(ctx, renameByIDFn, source, id, wasmabi.Text(newName))
}

// RemoveDeclaration produces the single edit that deletes a declaration.
//
// It deletes the declaration and only the declaration. Calls to a removed
// function, and uses of a removed variable, are left exactly where they were,
// so the result usually no longer type-checks — check with [Validate] if that
// matters. Removing what is not a declaration in its own right, such as a
// struct member or a function parameter, is [ErrNotRemovable].
func RemoveDeclaration(ctx context.Context, source string, id StableID) ([]Edit, error) {
	return editsByID(ctx, removeDeclarationFn, source, id)
}

// RemoveDeclarationApply deletes a declaration and returns the rewritten
// source. It leaves the uses of what it deleted behind, exactly as
// [RemoveDeclaration] describes.
func RemoveDeclarationApply(ctx context.Context, source string, id StableID) (Applied, error) {
	return appliedByID(ctx, removeDeclarationApplyFn, source, id)
}

// ChangeType produces the single edit that replaces a symbol's type
// annotation.
//
// The replacement is spliced in verbatim and is never checked: "not a type" is
// accepted and produces a shader that does not parse. Writing something WGSL
// will have is the caller's job.
//
// A symbol with no annotation to replace — an inferred let, an entry point
// with no return type — is [ErrNoTypeAnnotation]. [LocateType] answers the
// same question without changing anything.
func ChangeType(ctx context.Context, source string, id StableID, newType string) ([]Edit, error) {
	if err := checkUTF8("new type", newType); err != nil {
		return nil, err
	}
	return editsByID(ctx, changeTypeFn, source, id, wasmabi.Text(newType))
}

// ChangeTypeApply replaces a symbol's type annotation and returns the
// rewritten source. The replacement is unchecked, exactly as [ChangeType]
// describes.
func ChangeTypeApply(ctx context.Context, source string, id StableID, newType string) (Applied, error) {
	if err := checkUTF8("new type", newType); err != nil {
		return Applied{}, err
	}
	return appliedByID(ctx, changeTypeApplyFn, source, id, wasmabi.Text(newType))
}

// editsByID and appliedByID are the shared bodies of the ID-addressed
// operations: check the two strings every one of them takes, then hand over to
// the envelope decoder. Extra arguments follow the ID, which is the order the
// guest expects.
func editsByID(ctx context.Context, fn, source string, id StableID, rest ...wasmabi.Arg) ([]Edit, error) {
	args, err := idArgs(source, id, rest)
	if err != nil {
		return nil, err
	}
	return editsFrom(ctx, fn, args...)
}

func appliedByID(ctx context.Context, fn, source string, id StableID, rest ...wasmabi.Arg) (Applied, error) {
	args, err := idArgs(source, id, rest)
	if err != nil {
		return Applied{}, err
	}
	return appliedFrom(ctx, fn, args...)
}

func idArgs(source string, id StableID, rest []wasmabi.Arg) ([]wasmabi.Arg, error) {
	if err := checkUTF8("source", source); err != nil {
		return nil, err
	}
	if err := checkUTF8("stable id", string(id)); err != nil {
		return nil, err
	}
	args := make([]wasmabi.Arg, 0, 2+len(rest))
	args = append(args, wasmabi.Text(source), wasmabi.Text(string(id)))
	return append(args, rest...), nil
}

// editsFrom decodes the envelope the five edit-producing operations share.
func editsFrom(ctx context.Context, fn string, args ...wasmabi.Arg) ([]Edit, error) {
	payload, err := refactorCall(ctx, fn, args...)
	if err != nil {
		return nil, err
	}
	var w struct {
		Edits []Edit `json:"edits"`
		Error string `json:"error"`
	}
	if err := decode(fn, payload, &w); err != nil {
		return nil, err
	}
	if err := refactorError(w.Error); err != nil {
		return nil, err
	}
	return w.Edits, nil
}

// appliedFrom decodes the envelope the three apply operations share.
//
// A failure arrives with the original source echoed back. The caller already
// has that, so what comes back here is the reason instead and the Applied is
// left zero — handing back an unchanged source under a nil error would make a
// refused rename look like one that had nothing to do.
func appliedFrom(ctx context.Context, fn string, args ...wasmabi.Arg) (Applied, error) {
	payload, err := refactorCall(ctx, fn, args...)
	if err != nil {
		return Applied{}, err
	}
	var w struct {
		OK     bool   `json:"ok"`
		Source string `json:"source"`
		Edits  []Edit `json:"edits"`
		Error  string `json:"error"`
	}
	if err := decode(fn, payload, &w); err != nil {
		return Applied{}, err
	}
	if err := refactorError(w.Error); err != nil {
		return Applied{}, err
	}
	// The engine sets ok false only alongside a reason, so this is
	// unreachable. It is checked anyway: the alternative is returning the
	// echoed original as though it were the rewrite, which is a wrong answer
	// rather than a missing one.
	if !w.OK {
		return Applied{}, fmt.Errorf("%w: %s refused the edit without saying why", ErrInternal, fn)
	}
	// Checking the source on the way in does not make this redundant, for the
	// same reason it does not in LintFix: the rewrite is a splice at byte
	// offsets, and one computed in the middle of a multi-byte rune would hand
	// back bytes that are no longer UTF-8 though every byte of the input was.
	if err := checkEngineUTF8("rewritten source", w.Source); err != nil {
		return Applied{}, err
	}
	return Applied{Source: w.Source, Edits: w.Edits}, nil
}
