package wgslender

import (
	"context"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
)

// Version returns the version of the wgslender engine embedded in this
// package, as a bare semver string such as "1.1.0".
//
// It is the version of the WebAssembly artifact, not of this Go module: the
// two are released together but versioned separately.
func Version(ctx context.Context) (string, error) {
	return wasmabi.Version(ctx)
}
