#!/usr/bin/env bash
# Mirror wgslender to another repository without tests.
#
# Usage:
#   ./scripts/mirror.sh <remote-url> [branch]
#
# Copies the working tree, removes tests/ and strips inline test blocks
# from src/*.zig using zig-test-stripper, then force-pushes to the remote.
#
# Requirements:
#   - zig (0.16.x+)
#   - zig-test-stripper source at ../zig-test-stripper (sibling directory)
#     or ZIG_TEST_STRIPPER_DIR env var pointing to its location

set -euo pipefail

REMOTE="${1:?Usage: $0 <remote-url> [branch]}"
BRANCH="${2:-main}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STRIPPER_DIR="${ZIG_TEST_STRIPPER_DIR:-$PROJECT_DIR/../zig-test-stripper}"

# --- Validate zig-test-stripper is available ---
if [ ! -f "$STRIPPER_DIR/build.zig" ]; then
    echo "error: zig-test-stripper not found at $STRIPPER_DIR"
    echo "Set ZIG_TEST_STRIPPER_DIR or clone it as a sibling directory."
    exit 1
fi

# --- Build zig-test-stripper ---
echo "Building zig-test-stripper..."
(cd "$STRIPPER_DIR" && zig build -Doptimize=ReleaseFast)
STRIPPER="$STRIPPER_DIR/zig-out/bin/zig-test-stripper"

if [ ! -x "$STRIPPER" ]; then
    echo "error: zig-test-stripper binary not found after build"
    exit 1
fi

# --- Copy to temp directory ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Copying project to temporary directory..."
rsync -a --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
    "$PROJECT_DIR/" "$TMP/repo/"

cd "$TMP/repo"
git init --quiet
git checkout -b "$BRANCH" --quiet

# --- Remove tests ---
echo "Removing tests/..."
rm -rf tests/

# --- Strip inline test blocks from src/*.zig ---
echo "Stripping inline tests from src/..."
for f in src/*.zig; do
    "$STRIPPER" -i "$f"
done

# --- Stage and commit ---
git add -A
git commit -m "Mirror: wgslender without tests" --quiet

# --- Push ---
echo "Pushing to $REMOTE ($BRANCH)..."
git push "$REMOTE" "$BRANCH" --force

echo "Done. Mirrored to $REMOTE ($BRANCH) without tests."
