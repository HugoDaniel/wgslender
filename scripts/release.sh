#!/usr/bin/env bash
# Rebuild every release artefact, test it, and prove the tree did not move.
#
# Usage:
#   ./scripts/release.sh              # regenerate, test, and leave the result staged for review
#   ./scripts/release.sh --check      # same, but restore the tree afterwards
#   SKIP_FOREIGN=1 ./scripts/release.sh   # Zig steps only (no go/cargo/npm)
#
# Bump src/root.zig's `pub const version` first — that edit is the whole
# manual part of a release. Everything below follows from it.
#
# The gate is the last step: `git diff --exit-code`. Steps 1-2 rewrite every
# generated and copied file in the repo, and both WASM builds are
# byte-reproducible from a cold cache, so a tree that moved after this script
# *is* the staleness error. That needs no hashes, no pins, and no maintenance
# — anything the build can regenerate is covered automatically, including
# files added years from now.
#
# Ordering matters: regenerate (1-2) before testing (3-7), so the suite runs
# against what will actually ship rather than against the pre-stamp tree. Then
# step 9 confirms the tested tree is the committed tree.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CHECK_ONLY=0
case "${1-}" in
    --check) CHECK_ONLY=1 ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

STEP=0
step() {
    STEP=$((STEP + 1))
    printf '\n\033[1m[%d/9] %s\033[0m\n' "$STEP" "$1"
}

# `have <cmd>` — foreign toolchains are optional. A missing one is reported and
# skipped rather than failing the run, so the Zig half stays usable on a
# machine without a Go or Rust toolchain. SKIP_FOREIGN=1 skips all three.
have() {
    [ "${SKIP_FOREIGN:-0}" = "1" ] && return 1
    command -v "$1" >/dev/null 2>&1
}

VERSION="$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' src/root.zig)"
if [ -z "$VERSION" ]; then
    echo "error: no \`pub const version\` in src/root.zig" >&2
    exit 1
fi
printf '\033[1mwgslender %s\033[0m — %s\n' "$VERSION" \
    "$([ "$CHECK_ONLY" = 1 ] && echo 'check only, tree will be restored' || echo 'release run')"

step "Stamp the version and regenerate the npm mirrors"
zig build gen-version gen-npm

step "Rebuild both WASM modules into every package that ships one"
zig build release-assets

step "Build the native artefacts"
zig build
zig build lsp

step "Zig test suite"
# -j1: the corpus suites are memory-heavy and flake when run concurrently.
zig build test -j1

step "Go package"
if have go; then
    (cd packages/go && go test ./...)
else
    echo "  skipped (no go toolchain, or SKIP_FOREIGN=1)"
fi

step "Rust package"
if have cargo; then
    (cd packages/rust && cargo xtask check)
else
    echo "  skipped (no cargo toolchain, or SKIP_FOREIGN=1)"
fi

step "npm package"
if have npm; then
    (cd packages/js-npm && npm test)
else
    echo "  skipped (no npm, or SKIP_FOREIGN=1)"
fi

# Reported, never applied. Auto-bumping dependencies inside a release is how an
# unrelated surprise ships in a patch release: the report tells you, and you
# decide in a separate commit, before you release.
step "Dependency freshness (report only — nothing is updated)"
if have go; then
    echo "--- go list -m -u all (packages/go)"
    (cd packages/go && go list -m -u all 2>/dev/null | grep '\[' || echo "  all current")
fi
if have cargo; then
    echo "--- cargo update --dry-run (packages/rust)"
    (cd packages/rust && cargo update --dry-run 2>&1 | grep -iE 'updating|upgrading' || echo "  all current")
fi
if have npm; then
    for pkg in npm/wgslender-vscode packages/js-npm; do
        echo "--- npm outdated ($pkg)"
        # npm outdated exits 1 when anything is outdated; that is information,
        # not a failure, so it must not trip `set -e`.
        (cd "$pkg" && npm outdated) || true
    done
fi

# The gate. Everything above rewrote what it owns; if that changed the tree,
# what is committed was stale.
step "Freshness gate: nothing regenerated may differ from what is committed"
if git diff --quiet; then
    echo "  clean — every generated and copied artefact matches what is committed"
else
    echo
    echo "  The files below were regenerated and differ from what is committed."
    echo "  That means the committed copies were stale. Review and commit them:"
    echo
    git status --short
    echo
    if [ "$CHECK_ONLY" = 1 ]; then
        echo "  --check: restoring the tree"
        git checkout -- .
    fi
    exit 1
fi

if [ "$CHECK_ONLY" = 1 ]; then
    echo
    echo "--check passed: a release from this tree would be reproducible."
    exit 0
fi

cat <<EOF

All green at ${VERSION}. Two tags, both on this commit — Go resolves a
subdirectory module by its path prefix, so it needs its own:

  git tag -a v${VERSION} -m 'wgslender ${VERSION}'
  git tag -a packages/go/v${VERSION} -m 'wgslender ${VERSION}'

Tagging is the irreversible step, so it is yours to run. Then publish:

  (cd packages/js-npm && npm publish)
  (cd packages/rust  && cargo publish -p wgslender-sys -p wgslender-core -p wgslender-macros -p wgslender)
EOF
