package wgslender

import (
	"encoding/json"
	"fmt"
)

// MinifyOptions overrides wgslender's minification defaults.
//
// Every field is absent by default, so the zero value means *no overrides —
// wgslender's own defaults apply*, not *everything off*. The defaults are:
// [MinifyOptions.MinifyWhitespace], [MinifyOptions.MinifyIdentifiers],
// [MinifyOptions.MinifySyntax] and [MinifyOptions.TreeShaking] on, everything
// else off, no kept names.
//
// A nil *MinifyOptions means the same thing, so a caller with nothing to say
// passes nil.
//
// Note that [LintConfig], the other options type in this package, reads its
// zero value the opposite way: no rules at all. The asymmetry is the engine's,
// not this package's.
type MinifyOptions struct {
	// MinifyWhitespace strips whitespace and comments. On by default.
	MinifyWhitespace Opt[bool] `json:"minifyWhitespace,omitzero"`
	// MinifyIdentifiers renames identifiers to short names. On by default.
	MinifyIdentifiers Opt[bool] `json:"minifyIdentifiers,omitzero"`
	// MinifySyntax rewrites syntax into shorter equivalent forms. On by
	// default.
	MinifySyntax Opt[bool] `json:"minifySyntax,omitzero"`
	// TreeShaking drops declarations no entry point can reach. On by default.
	TreeShaking Opt[bool] `json:"treeShaking,omitzero"`
	// MangleExternalBindings renames @group/@binding variables too. Off by
	// default, because renaming them changes the names a host program binds
	// against.
	MangleExternalBindings Opt[bool] `json:"mangleExternalBindings,omitzero"`
	// PreserveUniformStructTypes keeps the type names of uniform and storage
	// structs intact. Off by default.
	PreserveUniformStructTypes Opt[bool] `json:"preserveUniformStructTypes,omitzero"`
	// KeepNames lists identifiers that must never be renamed. Names the shader
	// does not declare are ignored.
	KeepNames []string `json:"keepNames,omitzero"`
	// SortDeclarations groups similar module-level declarations together,
	// which compresses better. Off by default.
	SortDeclarations Opt[bool] `json:"sortDeclarations,omitzero"`
	// ScopeLocalRename reuses the same short names across sibling scopes,
	// which compresses better. Off by default.
	ScopeLocalRename Opt[bool] `json:"scopeLocalRename,omitzero"`
	// SourceMap asks for a source map alongside the minified output, returned
	// in [MinifyResult.SourceMap]. Off by default.
	SourceMap Opt[bool] `json:"sourceMap,omitzero"`
	// SourceMapSources embeds the original source text in that source map. Off
	// by default, and only meaningful with SourceMap set.
	SourceMapSources Opt[bool] `json:"sourceMapSources,omitzero"`
}

// emptyOptions is what the engine reads as "no overrides".
var emptyOptions = []byte("{}")

// encode renders the options as the JSON the engine reads. A nil receiver and
// a zero value both render as {}.
//
// The engine does not validate this document: it parses what it can and
// silently falls back to the defaults for anything it cannot (src/api_json.zig
// does Config.parseJson(...) catch Config{}). A malformed request is therefore
// answered, not refused, which is why the encoding lives here rather than being
// assembled by callers.
func (o *MinifyOptions) encode() ([]byte, error) {
	if o == nil {
		return emptyOptions, nil
	}
	b, err := json.Marshal(o)
	if err != nil {
		return nil, fmt.Errorf("wgslender: encoding minify options: %w", err)
	}
	return b, nil
}

// Strictness says whether [Validate] tolerates warnings.
//
// It is a named choice rather than a bool argument, so that the call site says
// which mode it means.
type Strictness int

const (
	// DefaultStrictness leaves warnings as warnings, and a shader with nothing
	// worse than warnings is valid.
	DefaultStrictness Strictness = iota
	// Strict promotes every warning to an error, so any diagnostic at all
	// rejects the shader.
	Strict
)

// optStrict is the engine's flag bit for strict mode (OPT_STRICT in
// src/wasm.zig).
const optStrict uint32 = 1 << 0

// flags is the guest's flag word for this mode.
func (s Strictness) flags() uint32 {
	if s == Strict {
		return optStrict
	}
	return 0
}

// A Pack is a shareable rule set, the equivalent of an extends entry in
// wgslender.json.
type Pack string

const (
	// PackRecommended is the default set: rules that catch likely mistakes.
	PackRecommended Pack = "@wgslender/recommended"
	// PackStyle covers formatting and naming conventions.
	PackStyle Pack = "@wgslender/style"
	// PackPerformance covers rules about shader cost.
	PackPerformance Pack = "@wgslender/performance"
	// PackPortability covers rules about running on more backends.
	PackPortability Pack = "@wgslender/portability"
	// PackMinify covers rules that make a shader minify better.
	PackMinify Pack = "@wgslender/minify"
	// PackStrict is everything, at error severity.
	PackStrict Pack = "@wgslender/strict"
)

// ruleSeverity is how loudly one rule reports. Its zero value is off, so that a
// [RuleSetting] nobody configured asks for nothing.
type ruleSeverity int

const (
	ruleOff ruleSeverity = iota
	ruleWarn
	ruleError
)

func (s ruleSeverity) String() string {
	switch s {
	case ruleWarn:
		return "warn"
	case ruleError:
		return "error"
	default:
		return "off"
	}
}

// A RuleSetting says what one lint rule should do. Build one with [Off],
// [Warn], [Error], [WarnWith] or [ErrorWith]; the zero value is [Off].
type RuleSetting struct {
	severity ruleSeverity
	// opts is the rule's own options object, nil when there is none. Which
	// options a rule takes is that rule's business, so this stays a map rather
	// than growing a type per rule.
	opts map[string]any
}

// Off does not run the rule, overriding whatever a pack said about it.
func Off() RuleSetting { return RuleSetting{severity: ruleOff} }

// Warn runs the rule, reporting at warning severity.
func Warn() RuleSetting { return RuleSetting{severity: ruleWarn} }

// Error runs the rule, reporting at error severity.
//
// Reporting at error severity is a statement about the shader, not about the
// call: [Lint] still returns a report rather than a Go error.
func Error() RuleSetting { return RuleSetting{severity: ruleError} }

// WarnWith runs the rule at warning severity with its own options. A nil map
// means the same as [Warn].
func WarnWith(opts map[string]any) RuleSetting {
	return RuleSetting{severity: ruleWarn, opts: opts}
}

// ErrorWith runs the rule at error severity with its own options. A nil map
// means the same as [Error].
func ErrorWith(opts map[string]any) RuleSetting {
	return RuleSetting{severity: ruleError, opts: opts}
}

// MarshalJSON writes the two forms the engine reads: a bare severity word, or a
// ["warn", {…}] pair when the rule was given options.
func (r RuleSetting) MarshalJSON() ([]byte, error) {
	if r.opts == nil {
		return json.Marshal(r.severity.String())
	}
	return json.Marshal([2]any{r.severity.String(), r.opts})
}

// A LintConfig says which rules to run, and how loudly.
//
// The zero value runs **no rules at all** — the opposite of [MinifyOptions],
// whose zero value means wgslender's own defaults. A nil *LintConfig means the
// same thing. Start from [PackRecommended] to get wgslender's opinion:
//
//	cfg := &wgslender.LintConfig{
//		Extends: []wgslender.Pack{wgslender.PackRecommended},
//		Rules:   map[string]wgslender.RuleSetting{"no-magic-numbers": wgslender.Off()},
//	}
//
// Rules win over anything Extends said.
type LintConfig struct {
	// Extends lists shareable packs to start from, in order.
	Extends []Pack `json:"extends,omitzero"`
	// Rules overrides individual rules by id. An id no rule answers to is
	// silently ignored — the engine does not report unknown rule names, so a
	// typo here reads as a rule that never fires.
	Rules map[string]RuleSetting `json:"rules,omitzero"`
	// ReportUnusedDisableDirectives reports wgslender-disable comments that
	// suppress nothing. Off by default.
	ReportUnusedDisableDirectives Opt[bool] `json:"reportUnusedDisableDirectives,omitzero"`
}

// encode renders the config as the JSON the engine reads. A nil receiver and a
// zero value both render as {}, which the engine reads as "run no rules".
func (c *LintConfig) encode() ([]byte, error) {
	if c == nil {
		return emptyOptions, nil
	}
	b, err := json.Marshal(c)
	if err != nil {
		return nil, fmt.Errorf("wgslender: encoding lint config: %w", err)
	}
	return b, nil
}
