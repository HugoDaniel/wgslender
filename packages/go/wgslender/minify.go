package wgslender

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/HugoDaniel/wgslender/packages/go/internal/wasmabi"
)

// The guest exports behind [Minify] and [MinifyAndReflect].
const (
	minifyFn        = "wgslender_minify_json"
	minifyReflectFn = "wgslender_minify_and_reflect"
)

// A MinifyResult is the outcome of minifying one shader.
//
// It is a report, not a success-or-failure: a shader the parser cannot read
// comes back with Code equal to the input and Errors describing why, because
// silently returning an empty shader would be worse than returning the one the
// caller already had.
type MinifyResult struct {
	// Code is the minified shader, or the original source verbatim if it did
	// not parse.
	Code string
	// Errors describes what stopped the minifier from doing better. It is
	// populated only by parse failures: a shader that parses but does not
	// type-check minifies normally and reports nothing here. Use [Validate] to
	// find out whether a shader is correct.
	Errors []string
	// OriginalSize is the byte length of the input.
	OriginalSize int
	// MinifiedSize is the byte length of Code.
	MinifiedSize int
	// SourceMap is a v3 source map, present only when
	// [MinifyOptions.SourceMap] asked for one. It stays raw JSON: the format
	// is standardised elsewhere and callers usually want to write it straight
	// to a file.
	SourceMap json.RawMessage
}

// Minify shrinks a WGSL shader. A nil opts means wgslender's defaults; see
// [MinifyOptions].
//
// The returned error reports a call that could not be made or trusted — source
// that is not valid UTF-8 ([ErrInvalidUTF8]), too large for the engine
// ([ErrSourceTooLarge]), an engine failure ([ErrInternal]) — and never a
// problem with the shader itself. Shader problems are in
// [MinifyResult.Errors], and a shader that does not parse comes back unchanged
// rather than empty.
func Minify(ctx context.Context, source string, opts *MinifyOptions) (MinifyResult, error) {
	if err := checkUTF8("source", source); err != nil {
		return MinifyResult{}, err
	}
	encoded, err := opts.encode()
	if err != nil {
		return MinifyResult{}, err
	}
	res, err := wasmabi.Call(ctx, minifyFn, wasmabi.PackLenPrefixed,
		wasmabi.Text(source), wasmabi.Buffer(encoded))
	if err != nil {
		return MinifyResult{}, err
	}
	var w wireMinify
	if err := json.Unmarshal(res.Payloads[0], &w); err != nil {
		return MinifyResult{}, fmt.Errorf("wgslender: decoding the minify envelope: %w", err)
	}
	return w.result(), nil
}

// A MinifiedShader is what [MinifyAndReflect] produced: the minified shader,
// and a description of the interface it presents.
//
// [MinifyResult] is embedded, so Code, Errors and the sizes are reached
// directly.
type MinifiedShader struct {
	MinifyResult
	// Reflection describes the *original* source, with each name's minified
	// form alongside it in the NameMapped fields. That pairing is the reason
	// to call this instead of [Minify] and [Reflect] separately: it is what
	// lets a host look up the buffer layout it knows by its author's name and
	// bind it under the name that survived.
	Reflection Reflection
}

// MinifyAndReflect minifies a shader and reflects over it in one pass. A nil
// opts means wgslender's defaults; see [MinifyOptions].
//
// The two halves report parse failures independently — [MinifyResult.Errors]
// and [Reflection.Errors] — and say the same thing when they do.
func MinifyAndReflect(ctx context.Context, source string, opts *MinifyOptions) (MinifiedShader, error) {
	if err := checkUTF8("source", source); err != nil {
		return MinifiedShader{}, err
	}
	encoded, err := opts.encode()
	if err != nil {
		return MinifiedShader{}, err
	}
	res, err := wasmabi.Call(ctx, minifyReflectFn, wasmabi.PackLenPrefixed,
		wasmabi.Text(source), wasmabi.Buffer(encoded))
	if err != nil {
		return MinifiedShader{}, err
	}
	var w struct {
		Minify  wireMinify `json:"minify"`
		Reflect Reflection `json:"reflect"`
	}
	if err := json.Unmarshal(res.Payloads[0], &w); err != nil {
		return MinifiedShader{}, fmt.Errorf("wgslender: decoding the minify-and-reflect envelope: %w", err)
	}
	return MinifiedShader{MinifyResult: w.Minify.result(), Reflection: w.Reflect}, nil
}

// wireMinify is the engine's minify envelope, written by minifyJsonToJson in
// src/api_json.zig.
type wireMinify struct {
	Code         string          `json:"code"`
	Errors       []wireMessage   `json:"errors"`
	OriginalSize int             `json:"originalSize"`
	MinifiedSize int             `json:"minifiedSize"`
	SourceMap    json.RawMessage `json:"sourceMap"`
}

// wireMessage is how the minifier spells an error. Reflection spells the same
// thing as a bare string; flattening both to []string is what keeps that
// asymmetry inside this file.
type wireMessage struct {
	Message string `json:"message"`
}

func (w wireMinify) result() MinifyResult {
	return MinifyResult{
		Code:         w.Code,
		Errors:       messages(w.Errors),
		OriginalSize: w.OriginalSize,
		MinifiedSize: w.MinifiedSize,
		SourceMap:    w.SourceMap,
	}
}

// messages flattens the wire's error objects to their text, leaving an empty
// list nil so that callers can range over it either way.
func messages(ws []wireMessage) []string {
	if len(ws) == 0 {
		return nil
	}
	out := make([]string, len(ws))
	for i, w := range ws {
		out[i] = w.Message
	}
	return out
}
