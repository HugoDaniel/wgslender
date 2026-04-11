#!/bin/bash
# WGSL Minifier Benchmark Script
#
# Compares output size and gzipped size across:
#   - wgslender 1.0 (Zig) — minified text
#   - wgslender 1.0 (Zig) — BPE-compiled .wasm binary
#   - miniray 0.3.1 (Go)  — minified text (legacy)
#
# Usage:
#   ./scripts/benchmark.sh                              # all compute.toys shaders
#   ./scripts/benchmark.sh tests/testdata/compute.toys/bridge.wgsl
#   MINIRAY_BIN=/other/path ./scripts/benchmark.sh      # override miniray path

set -e

# Configuration
WGSLENDER_BIN="${WGSLENDER_BIN:-./zig-out/bin/wgslender}"
MINIRAY_BIN="${MINIRAY_BIN:-$HOME/Dev/miniray/build/miniray}"
TESTDATA_DIR="${TESTDATA_DIR:-tests/testdata/compute.toys}"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# ── Helpers ──────────────────────────────────────────────────────────────

gzip_size() {
    gzip -c "$1" | wc -c | tr -d ' '
}

pct() {
    local orig=$1 size=$2
    if [ "$orig" -gt 0 ] 2>/dev/null && [ "$size" -gt 0 ] 2>/dev/null; then
        echo "$((100 - size * 100 / orig))"
    else
        echo "-"
    fi
}

# ── Check dependencies ───────────────────────────────────────────────────

check_deps() {
    if [ ! -x "$WGSLENDER_BIN" ]; then
        echo -e "${RED}Error: wgslender not found at $WGSLENDER_BIN${NC}"
        echo "Run 'zig build' first"
        exit 1
    fi

    MINIRAY_AVAILABLE=false
    if [ -x "$MINIRAY_BIN" ]; then
        MINIRAY_AVAILABLE=true
    else
        echo -e "${DIM}miniray not found at $MINIRAY_BIN — skipping legacy comparison${NC}"
    fi
}

# ── Benchmark one file ───────────────────────────────────────────────────

benchmark_file() {
    local file="$1"
    local name=$(basename "$file")
    local orig_size=$(wc -c < "$file" | tr -d ' ')
    local orig_gz=$(gzip_size "$file")

    # wgslender minify
    local zig_out="$TMP_DIR/zig_${name}"
    local zig_size="-" zig_gz="-"
    if "$WGSLENDER_BIN" "$file" > "$zig_out" 2>/dev/null; then
        zig_size=$(wc -c < "$zig_out" | tr -d ' ')
        zig_gz=$(gzip_size "$zig_out")
    fi

    # wgslender BPE compile
    local bpe_out="$TMP_DIR/bpe_${name%.wgsl}.wasm"
    local bpe_size="-" bpe_gz="-"
    if "$WGSLENDER_BIN" compile "$file" -o "$bpe_out" 2>/dev/null; then
        bpe_size=$(wc -c < "$bpe_out" | tr -d ' ')
        bpe_gz=$(gzip_size "$bpe_out")
    fi

    # miniray (Go legacy)
    local go_size="-" go_gz="-"
    if [ "$MINIRAY_AVAILABLE" = true ]; then
        local go_out="$TMP_DIR/go_${name}"
        if "$MINIRAY_BIN" "$file" > "$go_out" 2>/dev/null; then
            go_size=$(wc -c < "$go_out" | tr -d ' ')
            go_gz=$(gzip_size "$go_out")
        fi
    fi

    # Output row
    printf "  %-26s %6s %6s" "$name" "$orig_size" "$orig_gz"
    printf "  │ %6s %6s %4s%%" "$zig_size" "$zig_gz" "$(pct "$orig_size" "$zig_size")"
    printf "  │ %6s %6s %4s%%" "$bpe_size" "$bpe_gz" "$(pct "$orig_size" "$bpe_size")"
    if [ "$MINIRAY_AVAILABLE" = true ]; then
        printf "  │ %6s %6s %4s%%" "$go_size" "$go_gz" "$(pct "$orig_size" "$go_size")"
    fi
    echo ""

    # Accumulate totals (store in temp file for subshell workaround)
    echo "$orig_size $orig_gz $zig_size $zig_gz $bpe_size $bpe_gz $go_size $go_gz" >> "$TMP_DIR/totals.txt"
}

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    check_deps

    # Collect files
    local files=()
    if [ -n "$1" ]; then
        files=("$@")
    elif [ -d "$TESTDATA_DIR" ]; then
        for f in "$TESTDATA_DIR"/*.wgsl; do
            [ -f "$f" ] && files+=("$f")
        done
        # Also include large shaders from testdata root
        for f in tests/testdata/sceneW.wgsl tests/testdata/sceneE.wgsl tests/testdata/sceneY.wgsl tests/testdata/starsParticlesModule.wgsl; do
            [ -f "$f" ] && files+=("$f")
        done
    else
        echo -e "${RED}No test files found.${NC}"
        echo "Usage: $0 [file1.wgsl file2.wgsl ...]"
        exit 1
    fi

    # Header
    echo ""
    echo -e "${BOLD}WGSL Minifier Benchmark${NC}"
    echo -e "${DIM}wgslender: $WGSLENDER_BIN"
    [ "$MINIRAY_AVAILABLE" = true ] && echo -e "miniray:   $MINIRAY_BIN"
    echo -e "files:     ${#files[@]}${NC}"
    echo ""

    echo -ne "  ${BOLD}"
    printf "%-26s %6s %6s" "File" "raw" "gzip"
    printf "  │ %6s %6s %5s" "raw" "gzip" "red."
    printf "  │ %6s %6s %5s" "raw" "gzip" "red."
    [ "$MINIRAY_AVAILABLE" = true ] && printf "  │ %6s %6s %5s" "raw" "gzip" "red."
    echo -e "${NC}"

    printf "  %-26s %6s %6s" "" "" ""
    printf "  │  ${BOLD}wgslender minify${NC}  "
    printf "  │  ${BOLD}wgslender BPE${NC}    "
    [ "$MINIRAY_AVAILABLE" = true ] && printf "  │  ${BOLD}miniray (Go)${NC}     "
    echo ""

    printf "  %-26s" "─────────────────────────"
    printf " ──────────────"
    printf "─┼────────────────────"
    printf "─┼────────────────────"
    [ "$MINIRAY_AVAILABLE" = true ] && printf "─┼────────────────────"
    echo ""

    # Reset totals
    > "$TMP_DIR/totals.txt"

    for file in "${files[@]}"; do
        [ -f "$file" ] && benchmark_file "$file"
    done

    # Compute totals
    local t_orig=0 t_orig_gz=0 t_zig=0 t_zig_gz=0 t_bpe=0 t_bpe_gz=0 t_go=0 t_go_gz=0
    while read -r o og z zg b bg g gg; do
        [ "$o" != "-" ] && t_orig=$((t_orig + o))
        [ "$og" != "-" ] && t_orig_gz=$((t_orig_gz + og))
        [ "$z" != "-" ] && t_zig=$((t_zig + z))
        [ "$zg" != "-" ] && t_zig_gz=$((t_zig_gz + zg))
        [ "$b" != "-" ] && t_bpe=$((t_bpe + b))
        [ "$bg" != "-" ] && t_bpe_gz=$((t_bpe_gz + bg))
        [ "$g" != "-" ] && t_go=$((t_go + g))
        [ "$gg" != "-" ] && t_go_gz=$((t_go_gz + gg))
    done < "$TMP_DIR/totals.txt"

    # Totals row
    printf "  %-26s" "─────────────────────────"
    printf " ──────────────"
    printf "─┼────────────────────"
    printf "─┼────────────────────"
    [ "$MINIRAY_AVAILABLE" = true ] && printf "─┼────────────────────"
    echo ""

    echo -ne "  ${BOLD}"
    printf "%-26s %6s %6s" "TOTAL" "$t_orig" "$t_orig_gz"
    printf "  │ %6s %6s %4s%%" "$t_zig" "$t_zig_gz" "$(pct "$t_orig" "$t_zig")"
    printf "  │ %6s %6s %4s%%" "$t_bpe" "$t_bpe_gz" "$(pct "$t_orig" "$t_bpe")"
    [ "$MINIRAY_AVAILABLE" = true ] && printf "  │ %6s %6s %4s%%" "$t_go" "$t_go_gz" "$(pct "$t_orig" "$t_go")"
    echo -e "${NC}"

    # Summary
    echo ""
    echo -e "${BOLD}Gzip totals:${NC}"
    printf "  Original:          %6s bytes\n" "$t_orig_gz"
    printf "  wgslender minify:  %6s bytes  ${GREEN}(%s%% smaller than orig gzip)${NC}\n" "$t_zig_gz" "$(pct "$t_orig_gz" "$t_zig_gz")"
    printf "  wgslender BPE:     %6s bytes  ${GREEN}(%s%% smaller than orig gzip)${NC}\n" "$t_bpe_gz" "$(pct "$t_orig_gz" "$t_bpe_gz")"
    if [ "$MINIRAY_AVAILABLE" = true ]; then
        printf "  miniray (Go):      %6s bytes  ${GREEN}(%s%% smaller than orig gzip)${NC}\n" "$t_go_gz" "$(pct "$t_orig_gz" "$t_go_gz")"
    fi
    echo ""
}

main "$@"
