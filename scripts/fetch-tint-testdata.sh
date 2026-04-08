#!/usr/bin/env bash
# Fetch WGSL test shaders from Google's Dawn/Tint project.
#
# Usage:
#   ./scripts/fetch-tint-testdata.sh
#
# Downloads ~25k .wgsl files (~408 MB) into testdata/tint/ using a sparse
# checkout of the Dawn repository. Requires git.

set -euo pipefail

REPO_URL="https://dawn.googlesource.com/dawn"
CLONE_DIR="$(mktemp -d)"
DEST_DIR="$(cd "$(dirname "$0")/.." && pwd)/testdata/tint"

if [ -d "$DEST_DIR" ] && [ "$(find "$DEST_DIR" -name '*.wgsl' -maxdepth 1 -print -quit 2>/dev/null)" != "" ]; then
    count=$(find "$DEST_DIR" -name '*.wgsl' | wc -l | tr -d ' ')
    echo "testdata/tint/ already exists with $count .wgsl files — skipping."
    echo "To re-fetch, remove testdata/tint/ first."
    exit 0
fi

echo "Cloning Dawn repository (sparse, metadata only)..."
git clone --filter=blob:none --sparse "$REPO_URL" "$CLONE_DIR" --quiet

echo "Checking out test/tint/ directory..."
cd "$CLONE_DIR"
git sparse-checkout set test/tint

echo "Copying to testdata/tint/..."
mkdir -p "$DEST_DIR"
cp -r "$CLONE_DIR/test/tint/"* "$DEST_DIR/"

echo "Cleaning up..."
rm -rf "$CLONE_DIR"

count=$(find "$DEST_DIR" -name '*.wgsl' | wc -l | tr -d ' ')
echo "Done. $count .wgsl files in testdata/tint/"
