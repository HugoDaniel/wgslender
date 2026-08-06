package wgslender

// The diagnostic vocabulary, shared by [Validate], [Lint] and [LintFix]. The
// engine writes one diagnostic shape for all of them (src/Diagnostic.zig), so
// there is one Go type for all of them too.

// A Severity says how seriously to take a [Diagnostic].
//
// It is deliberately an open enum: the constants below are what the engine
// spells today, but a severity this package has never heard of arrives verbatim
// rather than being flattened into one of them. Compare against the constants,
// and expect the default branch to be reachable.
type Severity string

const (
	// SeverityError rejects the shader.
	SeverityError Severity = "error"
	// SeverityWarning is legal, but almost certainly not what the author meant.
	SeverityWarning Severity = "warning"
	// SeverityInfo is neutral commentary.
	SeverityInfo Severity = "info"
	// SeverityNote is extra context attached to another diagnostic.
	SeverityNote Severity = "note"
	// SeverityHint is a suggestion an editor can act on.
	SeverityHint Severity = "hint"
	// SeverityUnknown is what the engine falls back to when it has no better
	// word. It is a real wire value, not this package's fallback.
	SeverityUnknown Severity = "unknown"
)

// A Diagnostic is one thing the engine has to say about a shader.
//
// Positions are 1-based, the way every editor and compiler prints them.
type Diagnostic struct {
	// Severity is how serious it is.
	Severity Severity
	// Message is human-readable text, with no position prefix.
	Message string
	// Code is the stable identifier, such as E0100 or W0001. Parse errors
	// often have none, so this is empty more than rarely.
	Code string
	// Line is the 1-based line of the first offending byte.
	Line int
	// Column is the 1-based column of the first offending byte.
	Column int
	// SpecRef points at the section of the WGSL specification this rests on,
	// when there is one.
	SpecRef string
	// Source names what produced the diagnostic. Lint rules say
	// "wgslender-lint"; the parser and validator leave it empty, which is how
	// [LintReport.Diagnostics] can be told apart despite arriving in one array.
	Source string
	// Related is context elsewhere in the file — the earlier declaration a
	// name shadows, say.
	Related []RelatedInfo
	// Fix is the rewrite that resolves this diagnostic, present only on the
	// ones [LintFix] can apply. It describes a splice: replace Range with Text.
	Fix *Fix
}

// A RelatedInfo is a second place in the source that explains a [Diagnostic].
type RelatedInfo struct {
	// Line is the 1-based line.
	Line int
	// Column is the 1-based column.
	Column int
	// Message says why this place is relevant.
	Message string
}

// A Fix is a rewrite that resolves a [Diagnostic]: replace the source in Range
// with Text.
type Fix struct {
	// Range is the span to replace.
	Range Range
	// Text is what to put there. Empty means a deletion.
	Text string
}

// A Range is a half-open span of source, from Start up to but not including
// End.
type Range struct {
	// Start is where the span begins.
	Start Position
	// End is the first position after it.
	End Position
}

// A Position is one place in a source file, given three ways because different
// callers want different ones: editors want line and column, splicing wants the
// offset.
type Position struct {
	// Line is 1-based.
	Line int
	// Column is 1-based.
	Column int
	// Offset is a 0-based UTF-8 byte offset from the start of the source.
	Offset int
}

// wireDiagnostic is the engine's diagnostic object (src/Diagnostic.zig,
// entryToJson). Absent keys — code, specRef, source, related, fix — are omitted
// when empty rather than sent as null, so a zero value is the right default for
// every one of them.
type wireDiagnostic struct {
	Severity Severity      `json:"severity"`
	Message  string        `json:"message"`
	Code     string        `json:"code"`
	Line     int           `json:"line"`
	Column   int           `json:"column"`
	SpecRef  string        `json:"specRef"`
	Source   string        `json:"source"`
	Related  []wireRelated `json:"related"`
	Fix      *wireFix      `json:"fix"`
}

type wireRelated struct {
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Message string `json:"message"`
}

// wireFix is the one place the wire and the Go shape genuinely differ: the
// engine flattens the range into six sibling keys, where a Range reads better
// as two positions.
type wireFix struct {
	Range struct {
		StartLine   int `json:"startLine"`
		StartColumn int `json:"startColumn"`
		StartOffset int `json:"startOffset"`
		EndLine     int `json:"endLine"`
		EndColumn   int `json:"endColumn"`
		EndOffset   int `json:"endOffset"`
	} `json:"range"`
	Text string `json:"text"`
}

func (w wireDiagnostic) result() Diagnostic {
	d := Diagnostic{
		Severity: w.Severity,
		Message:  w.Message,
		Code:     w.Code,
		Line:     w.Line,
		Column:   w.Column,
		SpecRef:  w.SpecRef,
		Source:   w.Source,
	}
	if len(w.Related) > 0 {
		d.Related = make([]RelatedInfo, len(w.Related))
		for i, r := range w.Related {
			d.Related[i] = RelatedInfo(r)
		}
	}
	if w.Fix != nil {
		r := w.Fix.Range
		d.Fix = &Fix{
			Range: Range{
				Start: Position{Line: r.StartLine, Column: r.StartColumn, Offset: r.StartOffset},
				End:   Position{Line: r.EndLine, Column: r.EndColumn, Offset: r.EndOffset},
			},
			Text: w.Fix.Text,
		}
	}
	return d
}

// diagnostics converts a wire array, leaving an empty one nil so that callers
// can range over it either way.
func diagnostics(ws []wireDiagnostic) []Diagnostic {
	if len(ws) == 0 {
		return nil
	}
	out := make([]Diagnostic, len(ws))
	for i, w := range ws {
		out[i] = w.result()
	}
	return out
}
