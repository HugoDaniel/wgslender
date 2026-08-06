package wgslender_test

import (
	"crypto/sha256"
	"errors"
	"io/fs"
	"os"
	"regexp"
	"testing"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// Paths to the rest of the repo, relative to this package's directory
// (packages/go/wgslender). Both are optional: the tests that use them skip
// when the file is absent, so the module keeps building if it is ever
// extracted from this repo.
const (
	rootZigPath = "../../../src/root.zig"
	npmWasmPath = "../../js-npm/wgslender.wasm"
)

var (
	semverRE     = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	rootZigVerRE = regexp.MustCompile(`(?m)^pub const version = "([^"]+)";`)
)

func TestVersion(t *testing.T) {
	got, err := wgslender.Version(t.Context())
	if err != nil {
		t.Fatalf("Version: %v", err)
	}
	if !semverRE.MatchString(got) {
		t.Errorf("Version() = %q, want a bare semver string", got)
	}

	// The version above came out of the embedded wasm. Pin it against the Zig
	// constant the wasm was built from, so a stale artifact cannot pass itself
	// off as current.
	src, err := os.ReadFile(rootZigPath)
	if errors.Is(err, fs.ErrNotExist) {
		t.Skipf("%s absent; skipping the source pin", rootZigPath)
	}
	if err != nil {
		t.Fatalf("read %s: %v", rootZigPath, err)
	}
	m := rootZigVerRE.FindSubmatch(src)
	if m == nil {
		t.Fatalf("no `pub const version = \"...\";` in %s", rootZigPath)
	}
	if want := string(m[1]); got != want {
		t.Errorf("Version() = %q, want %q from %s\n"+
			"the embedded wasm is stale: rebuild with `zig build wasm` and refresh both copies",
			got, want, rootZigPath)
	}
}

// TestWasmMatchesNpm is the freshness gate. The Go package embeds its own copy
// of wgslender.wasm because go:embed cannot reach outside the module, so the
// two copies can drift silently — and a drifted copy does not crash, it
// answers questions using the old wire format. Whenever the wasm is rebuilt,
// this test fails until packages/go/internal/wasmabi/wgslender.wasm is
// refreshed too.
func TestWasmMatchesNpm(t *testing.T) {
	npm, err := os.ReadFile(npmWasmPath)
	if errors.Is(err, fs.ErrNotExist) {
		t.Skipf("%s absent; nothing to compare against", npmWasmPath)
	}
	if err != nil {
		t.Fatalf("read %s: %v", npmWasmPath, err)
	}
	want := sha256.Sum256(npm)
	if got := wasmabi.Checksum(); got != want {
		t.Errorf("embedded wasm sha256 = %x\n want (%s) = %x\n"+
			"refresh it: cp packages/js-npm/wgslender.wasm packages/go/internal/wasmabi/wgslender.wasm",
			got, npmWasmPath, want)
	}
}
