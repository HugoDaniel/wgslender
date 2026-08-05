#!/bin/sh
# Smoke tests for the C examples. Run via `make test`.
#
# Each example is a zero-argument program that prints to stdout, so a test is a
# binary plus the substrings its output has to contain. Adding coverage is a
# line in the table below, never new code.
#
# Substrings, not sizes: byte counts move whenever the minifier improves, and a
# suite that fails on an improvement is a suite people learn to ignore. What is
# pinned is shape — the section headers, the JSON keys, the WASM magic number —
# and, where it matters, the answer itself: `validate` has to print both
# `valid: true` and `valid: false`, or a validator that stopped rejecting
# anything would pass.
set -u
cd "$(dirname "$0")"

[ -f ../../zig-out/lib/libwgslender.a ] || {
	echo "libwgslender.a missing — run: zig build lib" >&2
	exit 2
}

pass=0
fail=0

# expect <binary> <required-substring>...
expect() {
	bin=$1
	shift
	out=$("./$bin" 2>&1)
	status=$?
	if [ "$status" -ne 0 ]; then
		echo "FAIL $bin: exit $status"
		fail=$((fail + 1))
		return
	fi
	for want in "$@"; do
		case "$out" in
		*"$want"*) ;;
		*)
			echo "FAIL $bin: output missing '$want'"
			fail=$((fail + 1))
			return
			;;
		esac
	done
	echo "ok   $bin"
	pass=$((pass + 1))
}

expect minify "wgslender " "Original (" "Minified (" "@vertex" "@fragment"
expect validate "--- valid shader ---" "valid: true" "valid: false" "--- strict mode ---" '"diagnostics"'
expect reflect '"version":2' '"bindings"' '"entryPoints"' '"structs"'
expect minify_and_reflect '"minify"' '"reflect"'
expect lint "lint:" "diagnostics:" "W0001"
expect lint_fix "fixed source"
expect rename "rename_apply JSON" '"edits"'
expect compile "magic: 00 61 73 6d"
expect change_type_apply_by_id "stable id: v1:" '"edits"'
expect remove_declaration_apply_by_id "stable id: v1:" '"edits"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
