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
