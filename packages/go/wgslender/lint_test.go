package wgslender_test

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// TestLint is the lint table. A new scenario is a row.
//
// Two of the rows exist to pin behaviour that reads like a bug until you know
// it is not: an empty config enables no rules at all, and WarningCount counts
// only the linter's warnings even though Diagnostics also carries the
// validator's.
func TestLint(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		config *wgslender.LintConfig
		check  func(*testing.T, wgslender.LintReport)
	}{
		{
			name:   "an empty config runs no rules at all",
			source: unusedWGSL,
			config: &wgslender.LintConfig{},
			check: func(t *testing.T, got wgslender.LintReport) {
				wantCounts(t, got, 0, 0, 0)
				if len(got.Diagnostics) != 0 {
					t.Errorf("Diagnostics = %+v, want none: no rules were enabled", got.Diagnostics)
				}
			},
		},
		{
			name:   "a nil config runs no rules either",
			source: unusedWGSL,
			config: nil,
			check: func(t *testing.T, got wgslender.LintReport) {
				wantCounts(t, got, 0, 0, 0)
			},
		},
		{
			name:   "the demo fixture passes the recommended pack",
			source: demoWGSL,
			config: &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}},
			check: func(t *testing.T, got wgslender.LintReport) {
				wantCounts(t, got, 0, 0, 0)
				if len(got.Diagnostics) != 0 {
					t.Errorf("Diagnostics = %+v, want none", got.Diagnostics)
				}
			},
		},
		{
			name:   "a single enabled rule finds the unused helper",
			source: unusedWGSL,
			config: &wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{"no-unused-vars": wgslender.RuleWarn()},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				if got.WarningCount != 1 {
					t.Errorf("WarningCount = %d, want 1", got.WarningCount)
				}
				if len(got.Diagnostics) == 0 {
					t.Fatal("expected a diagnostic for the unused helper")
				}
				first := got.Diagnostics[0]
				if first.Code != "W0001" {
					t.Errorf("Code = %q, want W0001", first.Code)
				}
				if first.Source != "wgslender-lint" {
					t.Errorf("Source = %q, want wgslender-lint", first.Source)
				}
				if first.Severity != wgslender.SeverityWarning {
					t.Errorf("Severity = %q, want %q", first.Severity, wgslender.SeverityWarning)
				}
				if !strings.Contains(first.Message, "unused_helper") {
					t.Errorf("Message = %q, want it to name the symbol", first.Message)
				}
			},
		},
		{
			name:   "a rule raised to error is counted as an error",
			source: unusedWGSL,
			config: &wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{"no-unused-vars": wgslender.RuleError()},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				if got.ErrorCount != 1 || got.WarningCount != 0 {
					t.Errorf("(ErrorCount, WarningCount) = (%d, %d), want (1, 0)",
						got.ErrorCount, got.WarningCount)
				}
			},
		},
		{
			name:   "a rule switched off is silent even when a pack asked for it",
			source: unusedWGSL,
			config: &wgslender.LintConfig{
				Extends: []wgslender.Pack{wgslender.PackRecommended},
				Rules:   map[string]wgslender.RuleSetting{"no-unused-vars": wgslender.RuleOff()},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				wantCounts(t, got, 0, 0, 0)
			},
		},
		{
			name:   "per-rule options reach the wire",
			source: unusedWGSL,
			config: &wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{
					"no-unused-vars": wgslender.RuleWarnWith(map[string]any{}),
				},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				if got.WarningCount != 1 {
					t.Errorf("WarningCount = %d, want 1", got.WarningCount)
				}
			},
		},
		{
			name:   "an unknown rule id is silently ignored",
			source: unusedWGSL,
			config: &wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{"no-such-rule": wgslender.RuleError()},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				if got.ErrorCount != 0 {
					t.Errorf("ErrorCount = %d, want 0: a typo disables the rule silently", got.ErrorCount)
				}
				if len(got.Diagnostics) != 0 {
					t.Errorf("Diagnostics = %+v, want none", got.Diagnostics)
				}
			},
		},
		{
			name:   "validator errors are counted even with no rules enabled",
			source: invalidWGSL,
			config: &wgslender.LintConfig{},
			check: func(t *testing.T, got wgslender.LintReport) {
				if got.ErrorCount != 1 {
					t.Errorf("ErrorCount = %d, want 1: the undeclared identifier counts", got.ErrorCount)
				}
				if len(got.Diagnostics) != 1 {
					t.Errorf("Diagnostics = %+v, want exactly the one error", got.Diagnostics)
				}
			},
		},
		{
			name:   "validator warnings reach the array but not the count",
			source: warningWGSL,
			config: &wgslender.LintConfig{},
			check: func(t *testing.T, got wgslender.LintReport) {
				if len(got.Diagnostics) != 2 {
					t.Errorf("Diagnostics = %+v, want the validator's two warnings", got.Diagnostics)
				}
				if got.WarningCount != 0 {
					t.Errorf("WarningCount = %d, want 0: the count is lint-only, and the "+
						"asymmetry is the engine's — pinned here so a change to it is visible",
						got.WarningCount)
				}
			},
		},
		{
			name:   "the recommended pack adds its own warnings on top",
			source: warningWGSL,
			config: &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}},
			check: func(t *testing.T, got wgslender.LintReport) {
				if len(got.Diagnostics) != 4 {
					t.Errorf("Diagnostics = %+v, want four: two validator, two lint", got.Diagnostics)
				}
				if got.WarningCount != 2 {
					t.Errorf("WarningCount = %d, want the two lint ones", got.WarningCount)
				}
				if got.FixableCount != 1 {
					t.Errorf("FixableCount = %d, want 1: the redundant cast is fixable", got.FixableCount)
				}
			},
		},
		{
			name:   "a disable comment silences the rule it names",
			source: unusedWithDirectiveWGSL,
			config: &wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{"no-unused-vars": wgslender.RuleWarn()},
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				wantCounts(t, got, 0, 0, 0)
				if len(got.Diagnostics) != 0 {
					t.Errorf("Diagnostics = %+v, want none", got.Diagnostics)
				}
			},
		},
		{
			name:   "a directive that silences nothing is reported when asked for",
			source: deadDirectiveWGSL,
			config: &wgslender.LintConfig{
				Extends:                       []wgslender.Pack{wgslender.PackRecommended},
				ReportUnusedDisableDirectives: wgslender.Set(true),
			},
			check: func(t *testing.T, got wgslender.LintReport) {
				var found bool
				for _, d := range got.Diagnostics {
					found = found || d.Code == "W0209"
				}
				if !found {
					t.Errorf("Diagnostics = %+v, want a W0209: the directive names a rule "+
						"that never fires", got.Diagnostics)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Lint(t.Context(), tt.source, tt.config)
			if err != nil {
				t.Fatalf("Lint: %v", err)
			}
			tt.check(t, got)
		})
	}
}

// wantCounts is the check the quiet rows share.
func wantCounts(t *testing.T, got wgslender.LintReport, errs, warns, fixable int) {
	t.Helper()
	if got.ErrorCount != errs || got.WarningCount != warns || got.FixableCount != fixable {
		t.Errorf("(ErrorCount, WarningCount, FixableCount) = (%d, %d, %d), want (%d, %d, %d)",
			got.ErrorCount, got.WarningCount, got.FixableCount, errs, warns, fixable)
	}
}

// TestLintConfigJSON pins the document the engine actually reads.
//
// It matters twice over: the engine answers a config it cannot parse with
// silence rather than a complaint, and its rules-object syntax has a shape
// nothing else in this package uses — a severity word on its own, or a
// severity/options pair.
func TestLintConfigJSON(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		config wgslender.LintConfig
		want   string
	}{
		{
			name:   "the zero value asks for nothing",
			config: wgslender.LintConfig{},
			want:   `{}`,
		},
		{
			name: "packs and rules use their wire spelling",
			config: wgslender.LintConfig{
				Extends: []wgslender.Pack{wgslender.PackRecommended, wgslender.PackStrict},
				Rules: map[string]wgslender.RuleSetting{
					"no-magic-numbers": wgslender.RuleOff(),
					"no-shadow":        wgslender.RuleError(),
				},
				ReportUnusedDisableDirectives: wgslender.Set(true),
			},
			want: `{"extends":["@wgslender/recommended","@wgslender/strict"],` +
				`"rules":{"no-magic-numbers":"off","no-shadow":"error"},` +
				`"reportUnusedDisableDirectives":true}`,
		},
		{
			name: "rule options travel as a severity/options pair",
			config: wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{
					"max-params": wgslender.RuleWarnWith(map[string]any{"max": 4}),
				},
			},
			want: `{"rules":{"max-params":["warn",{"max":4}]}}`,
		},
		{
			name: "a setting with no options stays a bare word",
			config: wgslender.LintConfig{
				Rules: map[string]wgslender.RuleSetting{"no-shadow": wgslender.RuleWarnWith(nil)},
			},
			want: `{"rules":{"no-shadow":"warn"}}`,
		},
		{
			name: "directives can be switched off explicitly",
			config: wgslender.LintConfig{
				ReportUnusedDisableDirectives: wgslender.Set(false),
			},
			want: `{"reportUnusedDisableDirectives":false}`,
		},
		{
			name:   "an empty rule set is still nothing to say",
			config: wgslender.LintConfig{Rules: map[string]wgslender.RuleSetting{}},
			want:   `{"rules":{}}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := json.Marshal(tt.config)
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			if string(got) != tt.want {
				t.Errorf("Marshal =\n %s\nwant\n %s", got, tt.want)
			}
		})
	}
}

// TestRuleSettingZeroValueIsOff pins the choice that the zero value is the
// harmless one: a rule mentioned but not set up does nothing, rather than
// travelling as an empty severity the engine would have to guess about.
func TestRuleSettingZeroValueIsOff(t *testing.T) {
	t.Parallel()

	var zero wgslender.RuleSetting
	got, err := json.Marshal(zero)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if string(got) != `"off"` {
		t.Errorf("Marshal = %s, want \"off\"", got)
	}
}

// TestLintFix pins the three things a fixer has to get right: it rewrites, it
// consumes what it rewrote, and what comes out is still WGSL. The last is the
// load-bearing one — an autofix that produces invalid source is worse than no
// autofix at all.
func TestLintFix(t *testing.T) {
	t.Parallel()

	config := &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}}

	outcome, err := wgslender.LintFix(t.Context(), warningWGSL, config)
	if err != nil {
		t.Fatalf("LintFix: %v", err)
	}
	if outcome.Fixed == warningWGSL {
		t.Error("Fixed is the input verbatim, want the redundant cast rewritten")
	}
	if outcome.Report.FixableCount != 1 {
		t.Errorf("Report.FixableCount = %d, want 1 — the report describes the input, not the output",
			outcome.Report.FixableCount)
	}

	after, err := wgslender.Lint(t.Context(), outcome.Fixed, config)
	if err != nil {
		t.Fatalf("re-Lint: %v", err)
	}
	if after.FixableCount >= outcome.Report.FixableCount {
		t.Errorf("FixableCount went from %d to %d, want fixing to consume the fixable diagnostics",
			outcome.Report.FixableCount, after.FixableCount)
	}

	report, err := wgslender.Validate(t.Context(), outcome.Fixed, wgslender.DefaultStrictness)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if !report.Valid {
		t.Errorf("the fixed source does not validate: %+v", report.Diagnostics)
	}
}

// TestLintFixLeavesACleanShaderAlone pins that nothing to fix means nothing
// changes — byte for byte, including the trivia a rewrite would be free to
// reflow.
func TestLintFixLeavesACleanShaderAlone(t *testing.T) {
	t.Parallel()

	config := &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}}
	outcome, err := wgslender.LintFix(t.Context(), demoWGSL, config)
	if err != nil {
		t.Fatalf("LintFix: %v", err)
	}
	if outcome.Fixed != demoWGSL {
		t.Errorf("Fixed = %q, want the input unchanged", outcome.Fixed)
	}
	if outcome.Report.FixableCount != 0 {
		t.Errorf("Report.FixableCount = %d, want 0", outcome.Report.FixableCount)
	}
}

func TestLintRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	if _, err := wgslender.Lint(t.Context(), "let\x95", nil); !errors.Is(err, wgslender.ErrInvalidUTF8) {
		t.Errorf("Lint = %v, want ErrInvalidUTF8", err)
	}
	if _, err := wgslender.LintFix(t.Context(), "let\x95", nil); !errors.Is(err, wgslender.ErrInvalidUTF8) {
		t.Errorf("LintFix = %v, want ErrInvalidUTF8", err)
	}
}
