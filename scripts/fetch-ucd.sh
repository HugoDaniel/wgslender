#!/usr/bin/env bash
# Fetch the Unicode Character Database DerivedCoreProperties.txt.
#
# Usage:
#   ./scripts/fetch-ucd.sh
#   UCD_VERSION=<x.y.z> ./scripts/fetch-ucd.sh   # override the pinned version
#
# Downloads DerivedCoreProperties.txt for the version pinned in
# scripts/ucd.rev into tests/testdata/ucd/ (git-ignored). This is the input to
# `zig build gen-xid`, which regenerates src/unicode_xid_data.zig. The
# generated data file is what's committed — the raw UCD is fetched on demand,
# like the Tint corpus. Requires curl.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REV_FILE="$ROOT_DIR/scripts/ucd.rev"
DEST_DIR="$ROOT_DIR/tests/testdata/ucd"
DEST_FILE="$DEST_DIR/DerivedCoreProperties.txt"

if [ ! -f "$REV_FILE" ]; then
    echo "error: pinned version file not found: $REV_FILE" >&2
    exit 1
fi
# Pinned Unicode version: env override wins, otherwise the tracked rev file.
UCD_VERSION="${UCD_VERSION:-$(tr -d '[:space:]' < "$REV_FILE")}"
URL="https://www.unicode.org/Public/${UCD_VERSION}/ucd/DerivedCoreProperties.txt"

if [ -f "$DEST_FILE" ]; then
    echo "tests/testdata/ucd/DerivedCoreProperties.txt already exists — skipping."
    echo "To re-fetch: remove it first."
    echo "To bump the pinned version: edit scripts/ucd.rev, then"
    echo "  rm -rf tests/testdata/ucd && ./scripts/fetch-ucd.sh &&"
    echo "  zig build gen-xid > src/unicode_xid_data.zig && zig build test"
    echo "(update the pinned counts in src/unicode_xid.zig if they change; commit"
    echo " scripts/ucd.rev + src/unicode_xid_data.zig together)."
    exit 0
fi

echo "Downloading DerivedCoreProperties.txt for Unicode $UCD_VERSION ..."
mkdir -p "$DEST_DIR"
curl -fsSL "$URL" -o "$DEST_FILE"

lines=$(wc -l < "$DEST_FILE" | tr -d ' ')
echo "Done. $lines lines in $DEST_FILE (Unicode $UCD_VERSION)"
echo "Next: zig build gen-xid > src/unicode_xid_data.zig"
