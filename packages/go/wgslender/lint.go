package wgslender

import (
	"context"
	"encoding/json"
	"fmt"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
)

// The guest exports behind [Lint] and [LintFix].
const (
	lintFn    = "wgslender_lint"
	lintFixFn = "wgslender_lint_fix"
)

// A LintReport is what [Lint] found.
//
// The counts and the diagnostics do not add up, and that is the engine's shape
// rather than an oversight here: ErrorCount covers the validator's errors as
// well as the linter's, while WarningCount covers only the linter's — even
// though Diagnostics also carries the validator's warnings. Count the
// severities in Diagnostics yourself if you need a total.
type LintReport struct {
	// ErrorCount is validator errors plus lint errors.
	ErrorCount int
	// WarningCount is lint warnings only.
	WarningCount int
	// FixableCount is how many diagnostics carry an autofix [LintFix] can
	// apply.
	FixableCount int
	// Diagnostics is everything found, the validator's first and then the
	// linter's. Lint entries are the ones whose [Diagnostic.Source] is
	// "wgslender-lint".
	Diagnostics []Diagnostic
}

// A LintFixOutcome is what [LintFix] produced.
type LintFixOutcome struct {
	// Fixed is the source with every available autofix applied.
	Fixed string
	// Report describes the source **as it was handed in**, not Fixed. Run
	// [Lint] on Fixed to see what is left.
	Report LintReport
}

// Lint runs the configured rules over a shader. A nil cfg runs no rules at all;
// see [LintConfig].
//
// Rule violations are not a Go error: they come back as a report. The returned
// error is reserved for a call that could not be made or trusted — see
// [ErrInvalidUTF8], [ErrSourceTooLarge] and [ErrInternal].
func Lint(ctx context.Context, source string, cfg *LintConfig) (LintReport, error) {
	res, err := lintCall(ctx, lintFn, wasmabi.PackLint, source, cfg)
	if err != nil {
		return LintReport{}, err
	}
	return decodeLintReport(res.Words[0], res.Words[1], res.Payloads[0])
}

// LintFix lints a shader and applies every autofix in one pass.
//
// Rules whose diagnostics carry no fix are reported and left alone, so the
// returned source can still lint dirty. It is always valid WGSL, though: an
// autofix that broke the shader would be worse than no autofix at all.
func LintFix(ctx context.Context, source string, cfg *LintConfig) (LintFixOutcome, error) {
	res, err := lintCall(ctx, lintFixFn, wasmabi.PackLintFix, source, cfg)
	if err != nil {
		return LintFixOutcome{}, err
	}
	fixed := string(res.Payloads[0])
	// Checking the source on the way in does not make this redundant. A fix is
	// a splice at byte offsets, and a rule that computed one in the middle of a
	// multi-byte rune would hand back bytes that are no longer UTF-8 even
	// though every byte of the input was.
	if err := checkEngineUTF8("fixed source", fixed); err != nil {
		return LintFixOutcome{}, err
	}
	report, err := decodeLintReport(res.Words[1], res.Words[2], res.Payloads[1])
	if err != nil {
		return LintFixOutcome{}, err
	}
	return LintFixOutcome{Fixed: fixed, Report: report}, nil
}

// lintCall is the half [Lint] and [LintFix] share: check the source, encode the
// config, and hand both to the named export.
func lintCall(ctx context.Context, fn string, l wasmabi.Layout, source string, cfg *LintConfig) (wasmabi.Result, error) {
	if err := checkUTF8("source", source); err != nil {
		return wasmabi.Result{}, err
	}
	encoded, err := cfg.encode()
	if err != nil {
		return wasmabi.Result{}, err
	}
	return wasmabi.Call(ctx, fn, l, wasmabi.Text(source), wasmabi.Buffer(encoded))
}

// decodeLintReport assembles a report from the two counts the envelope header
// carries and the JSON that carries the rest. Both exports pack the same three
// things; only where the words sit differs.
func decodeLintReport(errorCount, warningCount uint32, payload []byte) (LintReport, error) {
	var w wireLintReport
	if err := json.Unmarshal(payload, &w); err != nil {
		return LintReport{}, fmt.Errorf("wgslender: decoding the lint envelope: %w", err)
	}
	return LintReport{
		ErrorCount:   int(errorCount),
		WarningCount: int(warningCount),
		FixableCount: w.FixableCount,
		Diagnostics:  diagnostics(w.Diagnostics),
	}, nil
}

// wireLintReport names what the envelope's header does not carry. Both counts
// are in the header and are read from there, as in [Validate]; fixableCount is
// only ever in the JSON.
type wireLintReport struct {
	FixableCount int              `json:"fixableCount"`
	Diagnostics  []wireDiagnostic `json:"diagnostics"`
}
