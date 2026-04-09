# Dawn Tint Test Suite for Wgslender

## Overview

Wgslender uses ~1,500 WGSL test files from the Dawn Tint test suite to validate minification correctness. These tests verify that minified code parses correctly and passes semantic validation.

**Source:** Dawn repository `test/tint/` directory
**Target:** `tests/testdata/tint/` (not committed, must be imported locally)

## Running the Tests

### 1. Import Test Files

The test files must be imported from a local Dawn repository clone:

```bash
# Clone Dawn if you haven't already
git clone https://dawn.googlesource.com/dawn ~/Development/dawn

# Create testdata directory
mkdir -p tests/testdata/tint

# Import test categories
cp -r ~/Development/dawn/test/tint/expressions tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/statements tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/bug/tint tests/testdata/tint/bug/
cp -r ~/Development/dawn/test/tint/types tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/samples tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/benchmark tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/shadowing tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/loops tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/var tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/identifiers tests/testdata/tint/
cp -r ~/Development/dawn/test/tint/out_of_order_decls tests/testdata/tint/
```

### 2. Run Tests

```bash
# Run all Tint semantic preservation tests
go test ./internal/minifier_tests/... -run TestTintSemanticPreservation -v

# Quick summary (pass/fail counts only)
go test ./internal/minifier_tests/... -run TestTintSemanticPreservation

# Run specific category
go test ./internal/minifier_tests/... -run "TestTintSemanticPreservation/expressions" -v
go test ./internal/minifier_tests/... -run "TestTintSemanticPreservation/bug" -v
```

### 3. Expected Output

```
=== RUN   TestTintSemanticPreservation
    tint_test.go:65: Tint tests: 1445 total, 572 passed, 0 failed, 0 skipped
--- PASS: TestTintSemanticPreservation (1.50s)
```

Tests are skipped (not failed) when:
- File uses unsupported WGSL features (f16, chromium extensions)
- Original file has parse errors (intentional test cases)
- Original file has validation errors (intentional test cases)
- Validator panics on complex constructs

## Test Categories

| Category | Files | Purpose |
|----------|-------|---------|
| expressions/binary | ~950 | Operator precedence, type coercion |
| statements | ~210 | Control flow preservation |
| bug/tint | ~260 | Edge cases, regression tests |
| types | ~170 | Type system integrity |
| samples + benchmark | ~20 | Real-world shader validation |
| shadowing | ~20 | Name resolution |
| loops | ~30 | Loop semantics |
| var | ~55 | Variable declarations |
| identifiers | ~20 | Identifier resolution |
| out_of_order_decls | ~10 | Declaration ordering |
| builtins (subset) | ~200 | Built-in function tests |

## How It Works

The test harness (`internal/minifier_tests/tint_test.go`) performs semantic preservation testing:

1. **Parse** original WGSL with wgslender parser
2. **Validate** original (skip if errors - likely intentional test case)
3. **Minify** with full options (whitespace, identifiers, syntax)
4. **Re-parse** minified output
5. **Re-validate** minified output
6. **Verify** entry points and bindings are preserved

## Bugs Found

These tests helped identify and fix:

1. **Printer `>=` bug**: Type templates like `vec3<i32>` followed by `=` created `>=` operator
2. **Renamer duplicate name bug**: Symbols with `UseCount=0` kept original names, causing conflicts

## Notes

- Test files are excluded from git (17MB+) via `.gitignore`
- Some tests use features wgslender doesn't support (f16, subgroups) - these are skipped
- Focus is on semantic preservation, not exact output matching
- Tests from `bug/` category are especially valuable for edge cases
