#!/bin/bash
# WGSL Minifier Benchmark Script
# Compares wgslender (Go) vs wgsl-minifier (Rust)
# Measures both output size and execution speed

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WGSLENDER_BIN="${WGSLENDER_BIN:-./build/wgslender}"
RUST_BIN="${RUST_BIN:-wgsl-minifier}"
ITERATIONS="${ITERATIONS:-10}"
TESTDATA_DIR="${TESTDATA_DIR:-tests/testdata}"

# Temp files
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Check dependencies
check_deps() {
    if [ ! -x "$WGSLENDER_BIN" ]; then
        echo -e "${RED}Error: wgslender not found at $WGSLENDER_BIN${NC}"
        echo "Run 'make build' first"
        exit 1
    fi

    if ! command -v "$RUST_BIN" &> /dev/null; then
        echo -e "${YELLOW}Warning: wgsl-minifier (Rust) not found${NC}"
        echo "Install with: cargo install wgsl-minifier"
        RUST_AVAILABLE=false
    else
        RUST_AVAILABLE=true
    fi

    if ! command -v bc &> /dev/null; then
        echo -e "${RED}Error: bc not found (needed for calculations)${NC}"
        exit 1
    fi
}

# Measure execution time (returns milliseconds)
measure_time() {
    local cmd="$1"
    local input="$2"
    local output="$3"
    local iterations="$4"

    local total_ms=0

    for ((i=1; i<=iterations; i++)); do
        local start=$(python3 -c 'import time; print(int(time.time() * 1000))')
        eval "$cmd" > /dev/null 2>&1 || true
        local end=$(python3 -c 'import time; print(int(time.time() * 1000))')
        local elapsed=$((end - start))
        total_ms=$((total_ms + elapsed))
    done

    echo "scale=2; $total_ms / $iterations" | bc
}

# Run benchmark on a single file
benchmark_file() {
    local file="$1"
    local filename=$(basename "$file")
    local orig_size=$(wc -c < "$file" | tr -d ' ')

    # wgslender benchmark
    local wgslender_out="$TMP_DIR/wgslender_${filename}"
    local wgslender_start=$(python3 -c 'import time; print(int(time.time() * 1000))')

    if "$WGSLENDER_BIN" "$file" > "$wgslender_out" 2>/dev/null; then
        local wgslender_end=$(python3 -c 'import time; print(int(time.time() * 1000))')
        local wgslender_size=$(wc -c < "$wgslender_out" | tr -d ' ')
        local wgslender_time=$(measure_time "\"$WGSLENDER_BIN\" \"$file\" > \"$wgslender_out\"" "" "" "$ITERATIONS")
        local wgslender_pct=$(echo "scale=0; 100 - ($wgslender_size * 100 / $orig_size)" | bc)
    else
        local wgslender_size="ERR"
        local wgslender_time="-"
        local wgslender_pct="-"
    fi

    # Rust benchmark
    if [ "$RUST_AVAILABLE" = true ]; then
        local rust_out="$TMP_DIR/rust_${filename}"
        rm -f "$rust_out"

        if "$RUST_BIN" "$file" "$rust_out" -f 2>/dev/null && [ -s "$rust_out" ]; then
            local rust_size=$(wc -c < "$rust_out" | tr -d ' ')
            local rust_time=$(measure_time "\"$RUST_BIN\" \"$file\" \"$rust_out\" -f" "" "" "$ITERATIONS")
            local rust_pct=$(echo "scale=0; 100 - ($rust_size * 100 / $orig_size)" | bc)
        else
            local rust_size="ERR"
            local rust_time="-"
            local rust_pct="-"
        fi
    else
        local rust_size="-"
        local rust_time="-"
        local rust_pct="-"
    fi

    # Output result
    printf "| %-28s | %8s | %7s | %7s | %6s%% | %6s%% | %8s | %8s |\n" \
        "$filename" "$orig_size" "$wgslender_size" "$rust_size" \
        "$wgslender_pct" "$rust_pct" "${wgslender_time}ms" "${rust_time}ms"
}

# Print header
print_header() {
    echo ""
    echo -e "${BLUE}=== WGSL Minifier Benchmark ===${NC}"
    echo -e "wgslender: $WGSLENDER_BIN"
    echo -e "wgsl-minifier: $RUST_BIN (available: $RUST_AVAILABLE)"
    echo -e "iterations: $ITERATIONS"
    echo ""
    echo "| File                         | Original | wgslender |    Rust | wgslender |   Rust |  wgslender |     Rust |"
    echo "|                              |    bytes |   bytes |   bytes |       % |      % |     time |     time |"
    echo "|------------------------------|----------|---------|---------|---------|--------|----------|----------|"
}

# Print summary
print_summary() {
    local total_orig=$1
    local total_wgslender=$2
    local total_rust=$3
    local wgslender_success=$4
    local rust_success=$5
    local total_files=$6
    local rust_orig=$7

    echo ""
    echo -e "${BLUE}=== Summary ===${NC}"
    echo ""

    if [ "$total_wgslender" -gt 0 ]; then
        local wgslender_total_pct=$(echo "scale=1; 100 - ($total_wgslender * 100 / $total_orig)" | bc)
        echo -e "${GREEN}wgslender:${NC}"
        echo "  Success: $wgslender_success/$total_files files"
        echo "  Total: $total_orig -> $total_wgslender bytes ($wgslender_total_pct% reduction)"
    fi

    if [ "$RUST_AVAILABLE" = true ] && [ "$total_rust" -gt 0 ]; then
        local rust_total_pct=$(echo "scale=1; 100 - ($total_rust * 100 / $rust_orig)" | bc)
        echo -e "${GREEN}wgsl-minifier (Rust):${NC}"
        echo "  Success: $rust_success/$total_files files"
        echo "  Total: $rust_orig -> $total_rust bytes ($rust_total_pct% reduction on successful files)"
    fi
}

# Main
main() {
    check_deps

    # Find test files
    local files=()
    if [ -n "$1" ]; then
        # Use provided files
        files=("$@")
    elif [ -d "$TESTDATA_DIR" ]; then
        # Use default testdata directory
        for f in "$TESTDATA_DIR"/*.wgsl; do
            [ -f "$f" ] && files+=("$f")
        done
    else
        echo -e "${RED}Error: No test files found${NC}"
        echo "Usage: $0 [file1.wgsl file2.wgsl ...]"
        echo "Or set TESTDATA_DIR to a directory containing .wgsl files"
        exit 1
    fi

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Error: No .wgsl files found${NC}"
        exit 1
    fi

    print_header

    local total_orig=0
    local total_wgslender=0
    local total_rust=0
    local rust_orig=0
    local wgslender_success=0
    local rust_success=0
    local total_files=${#files[@]}

    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            echo -e "${YELLOW}Warning: File not found: $file${NC}"
            continue
        fi

        # Run benchmark and capture output
        local result=$(benchmark_file "$file")
        echo "$result"

        # Parse result for summary (extract sizes)
        local orig=$(echo "$result" | awk -F'|' '{gsub(/[^0-9]/, "", $3); print $3}')
        local wgslender=$(echo "$result" | awk -F'|' '{gsub(/[^0-9]/, "", $4); print $4}')
        local rust=$(echo "$result" | awk -F'|' '{gsub(/[^0-9]/, "", $5); print $5}')

        if [ -n "$orig" ] && [ "$orig" -gt 0 ] 2>/dev/null; then
            total_orig=$((total_orig + orig))
        fi

        if [ -n "$wgslender" ] && [ "$wgslender" -gt 0 ] 2>/dev/null; then
            total_wgslender=$((total_wgslender + wgslender))
            wgslender_success=$((wgslender_success + 1))
        fi

        if [ -n "$rust" ] && [ "$rust" -gt 0 ] 2>/dev/null; then
            total_rust=$((total_rust + rust))
            rust_orig=$((rust_orig + orig))
            rust_success=$((rust_success + 1))
        fi
    done

    print_summary "$total_orig" "$total_wgslender" "$total_rust" "$wgslender_success" "$rust_success" "$total_files" "$rust_orig"
}

main "$@"
