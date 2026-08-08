#!/usr/bin/env bash
# Cross-check wgslender's reflection against `external/wgsl_reflect` for
# every shader in `tests/testdata/compute.toys/`. Reduces both reflectors
# to a canonical shape (group/binding/name/addressSpace/kind/size) and
# diffs — wgslender-specific extensions (stable_id, name_mapped, typeInfo,
# spans, relations, function call graph, per-entry resources, override
# linkage) are intentionally elided on both sides; see `cross_check_*.mjs`
# for the exact reducer.
#
# Exit code:
#   0  every shader matched
#   1  at least one shader diverged (full diff printed)
#   2  setup error (missing CLI / wgsl_reflect / Node)
#
# `external/wgsl_reflect` is not vendored — clone it yourself to run this:
#   git clone https://github.com/brendan-duncan/wgsl_reflect external/wgsl_reflect
#
# Usage:
#   tests/cross_check.sh                     # all shaders in compute.toys
#   tests/cross_check.sh path/to/file.wgsl   # one shader

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WGSLENDER_BIN="$REPO_ROOT/zig-out/bin/wgslender"
WGSL_REFLECT_PKG="$REPO_ROOT/external/wgsl_reflect/wgsl_reflect.module.js"

if [[ ! -x "$WGSLENDER_BIN" ]]; then
  echo "error: $WGSLENDER_BIN not built — run \`zig build\` first" >&2
  exit 2
fi
if [[ ! -f "$WGSL_REFLECT_PKG" ]]; then
  echo "error: $WGSL_REFLECT_PKG missing — clone it with" >&2
  echo "  git clone https://github.com/brendan-duncan/wgsl_reflect external/wgsl_reflect" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "error: node not in PATH" >&2
  exit 2
fi

if [[ $# -ge 1 ]]; then
  shaders=("$@")
else
  # Portable fallback for macOS bash 3.2 (no mapfile/readarray).
  shaders=()
  for f in "$REPO_ROOT/tests/testdata/compute.toys/"*.wgsl; do
    shaders+=("$f")
  done
fi

passed=0
failed=0
divergences=()

for shader in "${shaders[@]}"; do
  name="$(basename "$shader")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  # Run both reflectors in parallel; the canonical reducer takes care of
  # making the JSON comparable.
  node "$SCRIPT_DIR/cross_check_wgsl_reflect.mjs" "$shader" >"$tmp_dir/wgsl_reflect.json" 2>"$tmp_dir/wgsl_reflect.err" &
  ref_pid=$!

  "$WGSLENDER_BIN" reflect --compact --reflect-format v2 "$shader" \
    | node "$SCRIPT_DIR/cross_check_wgslender.mjs" \
    >"$tmp_dir/wgslender.json" 2>"$tmp_dir/wgslender.err"
  ours_status=$?

  wait $ref_pid || ref_status=$? && ref_status=${ref_status:-0}

  if [[ $ours_status -ne 0 ]] || [[ ${ref_status:-0} -ne 0 ]]; then
    failed=$((failed + 1))
    divergences+=("$name (reducer error)")
    echo "✗ $name"
    [[ -s "$tmp_dir/wgsl_reflect.err" ]] && { echo "  wgsl_reflect stderr:"; sed 's/^/    /' "$tmp_dir/wgsl_reflect.err"; }
    [[ -s "$tmp_dir/wgslender.err" ]] && { echo "  wgslender stderr:"; sed 's/^/    /' "$tmp_dir/wgslender.err"; }
    rm -rf "$tmp_dir"
    trap - EXIT
    continue
  fi

  if diff -u "$tmp_dir/wgsl_reflect.json" "$tmp_dir/wgslender.json" >"$tmp_dir/diff" 2>&1; then
    passed=$((passed + 1))
    echo "✓ $name"
  else
    failed=$((failed + 1))
    divergences+=("$name")
    echo "✗ $name"
    sed 's/^/    /' "$tmp_dir/diff"
  fi

  rm -rf "$tmp_dir"
  trap - EXIT
done

echo
echo "cross_check: $passed passed, $failed failed (${#shaders[@]} total)"

if [[ $failed -gt 0 ]]; then
  echo "diverged: ${divergences[*]}"
  exit 1
fi
exit 0
