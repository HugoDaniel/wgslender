#!/usr/bin/env bash
# Fetch WGSL test shaders from Google's Dawn/Tint project.
#
# Usage:
#   ./scripts/fetch-tint-testdata.sh
#   DAWN_REV=<sha> ./scripts/fetch-tint-testdata.sh   # override the pinned revision
#
# Downloads ~25k .wgsl files (~408 MB) into tests/testdata/tint/ using a sparse
# checkout of the Dawn repository, pinned to the revision recorded in
# scripts/tint-testdata.rev so the corpus (and the goldens derived from it) are
# reproducible instead of tracking a moving upstream HEAD. Requires git.

set -euo pipefail

REPO_URL="https://dawn.googlesource.com/dawn"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REV_FILE="$ROOT_DIR/scripts/tint-testdata.rev"
CLONE_DIR="$(mktemp -d)"
DEST_DIR="$ROOT_DIR/tests/testdata/tint"

if [ ! -f "$REV_FILE" ]; then
    echo "error: pinned revision file not found: $REV_FILE" >&2
    exit 1
fi
# Pinned dawn revision: env override wins, otherwise the tracked rev file.
DAWN_REV="${DAWN_REV:-$(tr -d '[:space:]' < "$REV_FILE")}"

if [ -d "$DEST_DIR" ] && [ "$(find "$DEST_DIR" -name '*.wgsl' -maxdepth 1 -print -quit 2>/dev/null)" != "" ]; then
    count=$(find "$DEST_DIR" -name '*.wgsl' | wc -l | tr -d ' ')
    echo "tests/testdata/tint/ already exists with $count .wgsl files — skipping."
    echo "To re-fetch: remove tests/testdata/tint/ first."
    echo "To bump the pinned revision: edit scripts/tint-testdata.rev, then"
    echo "  rm -rf tests/testdata/tint tests/inference/corpus_golden.txt tests/inference/triage_golden.txt &&"
    echo "  ./scripts/fetch-tint-testdata.sh && zig build test"
    echo "(regenerates both goldens against the new revision; commit rev + goldens together)."
    exit 0
fi

echo "Cloning Dawn repository (sparse, metadata only)..."
git clone --filter=blob:none --sparse "$REPO_URL" "$CLONE_DIR" --quiet

echo "Pinning to revision $DAWN_REV and checking out test/tint/ ..."
cd "$CLONE_DIR"
git sparse-checkout set test/tint
git checkout --quiet "$DAWN_REV"

echo "Copying to tests/testdata/tint/..."
mkdir -p "$DEST_DIR"
cp -r "$CLONE_DIR/test/tint/"* "$DEST_DIR/"

echo "Cleaning up..."
rm -rf "$CLONE_DIR"

count=$(find "$DEST_DIR" -name '*.wgsl' | wc -l | tr -d ' ')
echo "Done. $count .wgsl files in tests/testdata/tint/ (dawn $DAWN_REV)"
