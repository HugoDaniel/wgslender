package wgslender_test

import (
	"errors"
	"strings"
	"testing"

	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// TestValidate is the validation table. A new scenario is a row.
//
// The rows mirror the ones the Rust package and the npm suite pin, so the three
// bindings can be read against each other; where they disagree on how tightly
// to assert, this table takes the tighter one.
func TestValidate(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		source     string
		strictness wgslender.Strictness
		check      func(*testing.T, wgslender.Validation)
	}{
		{
			name:   "a plain function is clean",
			source: "fn foo() -> f32 { return 1.0; }",
			check: func(t *testing.T, got wgslender.Validation) {
				if !got.Valid || got.ErrorCount != 0 {
					t.Errorf("Valid = %v, ErrorCount = %d, want true and 0", got.Valid, got.ErrorCount)
				}
				if len(got.Diagnostics) != 0 {
					t.Errorf("Diagnostics = %+v, want none", got.Diagnostics)
				}
			},
		},
		{
			name:   "a compute entry point is clean",
			source: "@compute @workgroup_size(1) fn main() {}",
			check:  wantValid,
		},
		{
			name:   "a vertex entry point is clean",
			source: "@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }",
			check:  wantValid,
		},
		{
			name:   "the demo fixture is clean",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Validation) {
				wantValid(t, got)
				if got.WarningCount != 0 {
					t.Errorf("WarningCount = %d, want 0", got.WarningCount)
				}
			},
		},
		{
			name:   "an undeclared identifier is a located, coded error",
			source: invalidWGSL,
			check: func(t *testing.T, got wgslender.Validation) {
				if got.Valid {
					t.Error("Valid = true, want false")
				}
				if got.ErrorCount < 1 {
					t.Errorf("ErrorCount = %d, want at least 1", got.ErrorCount)
				}
				if len(got.Diagnostics) == 0 {
					t.Fatal("an invalid shader must produce a diagnostic")
				}
				first := got.Diagnostics[0]
				if first.Severity != wgslender.SeverityError {
					t.Errorf("Severity = %q, want %q", first.Severity, wgslender.SeverityError)
				}
				if !strings.HasPrefix(first.Code, "E") {
					t.Errorf("Code = %q, want a semantic error code beginning with E", first.Code)
				}
				if first.Line < 1 || first.Column < 1 {
					t.Errorf("Line, Column = %d, %d, want both at least 1 (positions are 1-based)",
						first.Line, first.Column)
				}
				if !strings.Contains(first.Message, "undeclared_variable") {
					t.Errorf("Message = %q, want it to name the offending symbol", first.Message)
				}
			},
		},
		{
			name:   "a type mismatch is rejected",
			source: "fn foo() -> f32 { var x: i32 = 1; return x; }",
			check: func(t *testing.T, got wgslender.Validation) {
				if got.Valid {
					t.Error("Valid = true, want false")
				}
			},
		},
		{
			name:   "unparseable source reports parse errors, some without a code",
			source: unparseableWGSL,
			check: func(t *testing.T, got wgslender.Validation) {
				if got.Valid {
					t.Error("Valid = true, want false")
				}
				if got.ErrorCount < 1 {
					t.Errorf("ErrorCount = %d, want at least 1", got.ErrorCount)
				}
				var uncoded bool
				for _, d := range got.Diagnostics {
					uncoded = uncoded || d.Code == ""
				}
				if !uncoded {
					t.Errorf("every diagnostic carries a code: %+v\n"+
						"some parse errors have none, which is why Code can be empty", got.Diagnostics)
				}
			},
		},
		{
			name:   "empty source is valid",
			source: "",
			check: func(t *testing.T, got wgslender.Validation) {
				wantValid(t, got)
				if got.WarningCount != 0 {
					t.Errorf("WarningCount = %d, want 0", got.WarningCount)
				}
			},
		},
		{
			name:   "warnings alone leave a shader valid",
			source: warningWGSL,
			check: func(t *testing.T, got wgslender.Validation) {
				wantValid(t, got)
				if got.WarningCount != 2 {
					t.Errorf("WarningCount = %d, want 2 (a redundant cast and unreachable code)",
						got.WarningCount)
				}
				for _, d := range got.Diagnostics {
					if d.Severity != wgslender.SeverityWarning {
						t.Errorf("Severity = %q, want every diagnostic to be a warning", d.Severity)
					}
				}
			},
		},
		{
			name:       "strict turns every warning into an error",
			source:     warningWGSL,
			strictness: wgslender.Strict,
			check: func(t *testing.T, got wgslender.Validation) {
				if got.Valid {
					t.Error("Valid = true, want false — strict mode rejects warnings")
				}
				if got.WarningCount != 0 {
					t.Errorf("WarningCount = %d, want 0 — nothing stays a warning", got.WarningCount)
				}
				if got.ErrorCount != 2 {
					t.Errorf("ErrorCount = %d, want 2", got.ErrorCount)
				}
				for _, d := range got.Diagnostics {
					if d.Severity != wgslender.SeverityError {
						t.Errorf("Severity = %q, want every diagnostic to be an error", d.Severity)
					}
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Validate(t.Context(), tt.source, tt.strictness)
			if err != nil {
				t.Fatalf("Validate: %v", err)
			}
			tt.check(t, got)
		})
	}
}

// wantValid is the check the clean rows share.
func wantValid(t *testing.T, got wgslender.Validation) {
	t.Helper()
	if !got.Valid {
		t.Errorf("Valid = false, want true; diagnostics: %+v", got.Diagnostics)
	}
	if got.ErrorCount != 0 {
		t.Errorf("ErrorCount = %d, want 0", got.ErrorCount)
	}
}

// TestValidateCountsComeFromTheEnvelopeHeader pins where the three numbers are
// read from.
//
// The guest packs them as four little-endian words — valid, errors, warnings,
// json length — ahead of the JSON, and this package reads the words rather than
// the JSON's own copy of them. That makes the field order load-bearing: shift
// it by one and every count silently becomes its neighbour. The warning fixture
// is the sharp case, because 1/0/2 is different in all three positions, and the
// fourth word is a JSON length far too large to pass for a count.
func TestValidateCountsComeFromTheEnvelopeHeader(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		source       string
		valid        bool
		errorCount   int
		warningCount int
	}{
		{"clean", demoWGSL, true, 0, 0},
		{"errors", invalidWGSL, false, 1, 0},
		{"warnings", warningWGSL, true, 0, 2},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Validate(t.Context(), tt.source, wgslender.DefaultStrictness)
			if err != nil {
				t.Fatalf("Validate: %v", err)
			}
			if got.Valid != tt.valid || got.ErrorCount != tt.errorCount || got.WarningCount != tt.warningCount {
				t.Errorf("(Valid, ErrorCount, WarningCount) = (%v, %d, %d), want (%v, %d, %d)",
					got.Valid, got.ErrorCount, got.WarningCount,
					tt.valid, tt.errorCount, tt.warningCount)
			}
		})
	}
}

// TestValidateStrictOnlyMovesDiagnostics pins the one thing strict mode must
// never do: lose a finding. It may only move findings from the warning column
// to the error column, which is why the counts are compared as a sum and the
// diagnostics as a length. The npm suite pins the same invariant.
func TestValidateStrictOnlyMovesDiagnostics(t *testing.T) {
	t.Parallel()

	lenient, err := wgslender.Validate(t.Context(), warningWGSL, wgslender.DefaultStrictness)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	strict, err := wgslender.Validate(t.Context(), warningWGSL, wgslender.Strict)
	if err != nil {
		t.Fatalf("Validate strict: %v", err)
	}

	if lenient.WarningCount < 1 {
		t.Fatalf("WarningCount = %d, want the fixture to produce warnings at all", lenient.WarningCount)
	}
	if want := lenient.ErrorCount + lenient.WarningCount; strict.ErrorCount < want {
		t.Errorf("strict ErrorCount = %d, want at least %d (%de + %dw promoted)",
			strict.ErrorCount, want, lenient.ErrorCount, lenient.WarningCount)
	}
	if len(strict.Diagnostics) != len(lenient.Diagnostics) {
		t.Errorf("strict reported %d diagnostics, lenient %d — strict must promote, not drop",
			len(strict.Diagnostics), len(lenient.Diagnostics))
	}
}

func TestValidateRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	got, err := wgslender.Validate(t.Context(), "let\x95", wgslender.DefaultStrictness)
	if !errors.Is(err, wgslender.ErrInvalidUTF8) {
		t.Fatalf("Validate = (%+v, %v), want ErrInvalidUTF8", got, err)
	}
}
