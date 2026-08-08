package wgslender

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/HugoDaniel/wgslender/packages/go/internal/wasmabi"
)

// validateFn is the guest export behind [Validate].
const validateFn = "wgslender_validate"

// A Validation is what [Validate] found.
type Validation struct {
	// Valid reports whether the shader is accepted. It is false whenever
	// ErrorCount is non-zero.
	Valid bool
	// ErrorCount is the number of error-severity diagnostics.
	ErrorCount int
	// WarningCount is the number of warning-severity diagnostics. Under
	// [Strict] it is always zero, because every warning became an error.
	WarningCount int
	// Diagnostics is everything the validator has to say, in source order.
	Diagnostics []Diagnostic
}

// Validate type-checks a WGSL shader.
//
// A shader that fails validation is not a Go error: it comes back with Valid
// false and the diagnostics that explain why. The returned error is reserved
// for a call that could not be made or trusted — see [ErrInvalidUTF8],
// [ErrSourceTooLarge] and [ErrInternal].
func Validate(ctx context.Context, source string, s Strictness) (Validation, error) {
	if err := checkUTF8("source", source); err != nil {
		return Validation{}, err
	}
	res, err := wasmabi.Call(ctx, validateFn, wasmabi.PackValidate,
		wasmabi.Text(source), wasmabi.Scalar(s.flags()))
	if err != nil {
		return Validation{}, err
	}
	var w wireValidation
	if err := json.Unmarshal(res.Payloads[0], &w); err != nil {
		return Validation{}, fmt.Errorf("wgslender: decoding the validate envelope: %w", err)
	}
	return Validation{
		Valid:        res.Words[0] != 0,
		ErrorCount:   int(res.Words[1]),
		WarningCount: int(res.Words[2]),
		Diagnostics:  diagnostics(w.Diagnostics),
	}, nil
}

// wireValidation names only what the envelope's header does not already carry.
//
// The engine sends the verdict and both counts twice — as the first three words
// of the envelope and again as keys in the JSON — and this package reads the
// words. They are the numbers the engine computed, they need no decoding, and
// taking them from one place means the two copies can never disagree here.
type wireValidation struct {
	Diagnostics []wireDiagnostic `json:"diagnostics"`
}
