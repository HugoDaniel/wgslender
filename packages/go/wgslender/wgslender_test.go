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
// (packages/go/wgslender). All are optional: the tests that use them skip
// when the file is absent, so the module keeps building if it is ever
// extracted from this repo.
const rootZigPath = "../../../src/root.zig"

// Every other in-tree copy of wgslender.wasm. `zig build release-assets`
// writes all of them, including this package's embedded one, from a single
// build — so any disagreement means one destination was refreshed by hand and
// another was not. The vscode copy is gitignored build output rather than a
// committed artefact, hence present only after a build.
var siblingWasmPaths = []string{
	"../../js-npm/wgslender.wasm",
	"../../../npm/wgslender-vscode/dist/wgslender.wasm",
}

const refreshHint = "refresh every copy: `zig build release-assets`"

var (
	semverRE     = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	rootZigVerRE = regexp.MustCompile(`(?m)^pub const version = "([^"]+)";`)
)

func TestVersion(t *testing.T) {
	t.Parallel()

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
			"the embedded wasm is stale: %s", got, want, rootZigPath, refreshHint)
	}
}

// TestWasmMatchesSiblings is the freshness gate. The Go package embeds its own
// copy of wgslender.wasm because go:embed cannot reach outside the module, so
// the copies can drift silently — and a drifted copy does not crash, it
// answers questions using the old wire format. Whenever the wasm is rebuilt,
// this test fails until packages/go/internal/wasmabi/wgslender.wasm is
// refreshed too.
//
// This proves the copies agree, not that any of them is current: a rebuild is
// the only thing that can prove that, and it lives in scripts/release.sh.
func TestWasmMatchesSiblings(t *testing.T) {
	t.Parallel()

	got := wasmabi.Checksum()
	compared := 0
	for _, path := range siblingWasmPaths {
		sibling, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		compared++
		if want := sha256.Sum256(sibling); got != want {
			t.Errorf("embedded wasm sha256 = %x\n want (%s) = %x\n%s", got, path, want, refreshHint)
		}
	}
	if compared == 0 {
		t.Skip("no sibling wasm copies present; nothing to compare against")
	}
}
