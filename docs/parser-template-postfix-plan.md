# Fix plan: postfix expressions inside `array<T, …>` template args

## Bug

`parseTemplatePrimaryExprInner` (`src/Parser.zig:1939`) returns immediately
after consuming an `ident` / `int_literal` / `(...)`. It never enters a
postfix loop, so `.dot`, `.l_bracket`, and `.l_paren` suffixes that
`parsePostfixExpr` (`src/Parser.zig:1644`) chains are silently dropped
inside `array<T, N>`-style template arguments.

Repro on `main`:

```sh
printf 'struct Pair { x: u32, y: u32 }
const P = Pair(4u, 0u);
@group(0) @binding(0) var<uniform> u: array<f32, P.x>;
' | ./zig-out/bin/wgslender reflect --compact
```

Output is `"type":"array<f32>"`, `elementCount: null`, `totalSize: null` —
the `.x` is silently consumed. The expected output is `elementCount: 4`,
`totalSize: 16`.

The restriction enforced by `parseTemplate*Expr` (no `>` / `>=`) was
applied at the wrong level: it should rule out binary `>` / `>=`, **not**
postfix member / index / call.

---

## 1. Chosen refactor — Option A (extract a helper)

`src/Parser.zig:1644-1705` — the postfix loop in `parsePostfixExpr` is
small but its CST bookkeeping (`saved` / `cstOpenBefore` /
`cst_last_closed_expr` / `left_marker`) is delicate enough that
duplicating it for the template path will rot. Factor the loop into:

```zig
fn applyPostfixSuffixes(self: *Parser, left_in: Ast.Expr, left_marker_in: ?Cst.Marker) !?Ast.Expr
```

- Takes the already-parsed primary as `left_in` and its closed CST
  marker as `left_marker_in`.
- Runs the existing `for (0..self.token_tags.len)` loop verbatim —
  `.dot`, `.l_bracket`, `.l_paren` arms, all three calling
  `parseExpression` / `parseExpressionList` for their bodies (justified
  in §3 below).
- Returns the post-postfix `left` and leaves `cst_last_closed_expr`
  correctly set to the outermost wrap marker (or to `left_marker_in` if
  no suffixes consumed).
- Returning `?Ast.Expr` preserves the existing `orelse return null`
  early-out inside the `[expr]` arm (line 1676).

`parsePostfixExpr` becomes a 2-liner:

```zig
fn parsePostfixExpr(self: *Parser) !?Ast.Expr {
    const primary = (try self.parsePrimaryExpr()) orelse return null;
    return self.applyPostfixSuffixes(primary, self.cst_last_closed_expr);
}
```

A new `parseTemplatePostfixExpr` mirrors it:

```zig
fn parseTemplatePostfixExpr(self: *Parser) !?Ast.Expr {
    const primary = (try self.parseTemplatePrimaryExpr()) orelse return null;
    return self.applyPostfixSuffixes(primary, self.cst_last_closed_expr);
}
```

`parseTemplateUnaryExpr` (`src/Parser.zig:1903`) changes its tail from
`return self.parseTemplatePrimaryExpr();` to
`return self.parseTemplatePostfixExpr();`. The recursive case (the
`if (op)` block) is untouched — unary still folds over a fully-postfixed
operand, mirroring `parseUnaryExpr` → `parsePostfixExpr` →
`parsePrimaryExpr`.

**Why not Option B (inline arms in a new wrapper)?** The three suffix
arms are 35 lines each carrying CST stamps that already had at least
one prior bug class (the `saved`/`left_marker` reset pattern). Forking
them invites silent drift — and the helper signature is genuinely tiny,
so the cost of A is negligible.

---

## 2. Exact AST + CST changes

**AST** — none. The fix produces existing nodes (`MemberExpr`,
`IndexExpr`, `CallExpr`) that Reflect.zig's `evalConst`/`evalMember`
already understand. No new node kinds, no field additions.

**CST** — the helper preserves the current contract from
`parsePostfixExpr`:

| Suffix | CST shape produced |
|---|---|
| `.dot` (member) | `cstOpenBefore(saved)` → close `.member_expr`; update `left_marker` to the wrap |
| `[expr]` (index) | `cstOpenBefore(saved)` → close `.index_expr`; index body parsed via `parseExpression` (full) |
| `(args)` (call) | `cstOpenBefore(saved)` → close `.call_expr`; args parsed via `parseExpressionList` (full) |

The `saved` snapshot at the top of each iteration must remain —
argument-list / index parses can reassign `self.cst_last_closed_expr`,
and the wrap target is the *previous* `left`'s marker, not whatever the
body just closed. The helper passes `left_marker_in` in and tracks it in
a local exactly as the current loop does at `src/Parser.zig:1649`.

On exit with no suffixes consumed, `cst_last_closed_expr` is **not**
touched — callers already rely on the primary's marker still being the
most recent closed expr (matches `parsePostfixExpr` line 1702 `else =>
return left`).

---

## 3. Subparser choice inside postfix arms (template path)

WGSL spec restricts unparenthesized `>` / `>=` only at the *top level* of
a template arg expression. Once inside `[...]` or `(...)`, the closing
bracket disambiguates and full expressions are legal. Concretely:

- `[expr]` — body fully bounded by `]`; use `parseExpression` (full).
  Same as the regular postfix.
- `(args)` — body fully bounded by `)`; use `parseExpressionList`
  (which uses full `parseExpression`). Same as the regular postfix.
- `.ident` — no recursion.

So the helper can use the **same** `parseExpression` /
`parseExpressionList` calls inside its arms whether invoked from the
regular or template paths. No threading of "are we in a template"
needed.

(Note: `parseTemplatePrimaryExprInner`'s existing `(...)` paren branch
at `src/Parser.zig:1961-1969` recurses via `parseTemplateArgExpr` rather
than full `parseExpression` — that's overly conservative but not the bug
we're fixing. **Out of scope; leave alone.**)

---

## 4. Verifying with the repro & const evaluator

`src/Reflect.zig:1761` already routes `.member` through `evalMember`,
which resolves `Pair(4u,0u).x → 4` (`src/Reflect.zig:1950-1985`). Once
the parser stops dropping `.x`, the user's repro should print
`"elementCount":4,"totalSize":16` with **zero** `Reflect.zig` changes.

Caveats to write into the plan but **not** address in this fix:

- `evalConst` does **not** handle `.index` (no `.index` arm in the
  switch at `src/Reflect.zig:1736-1763`). So `array<f32, arr[0]>` will
  parse correctly but reflect as `elementCount: null`. Tests assert AST
  shape only for that case (or skip reflection assertion).
- `evalCall` covers `radians`/`sin`/`u32(...)` already
  (`src/Reflect.zig:1881-1917`), so direct inline
  `array<vec4f, u32(sin(radians(90)) + 3)>` becomes resolvable for the
  first time.

---

## 5. Test plan

**New file** `tests/parser_template_postfix_test.zig` — parser-level
tests asserting the AST shape (no Reflect dependency). Use the existing
harness pattern from `tests/parser_test.zig`. Cases:

1. `var<uniform> u: array<f32, P.x>` → `ArrayType.size` is
   `MemberExpr{ base = IdentExpr("P"), member = "x" }`.
2. `var<uniform> u: array<f32, arr[0]>` → `IndexExpr{ base =
   IdentExpr("arr"), idx = LiteralExpr(0) }`.
3. `var<uniform> u: array<f32, P.x + 1>` → `BinaryExpr.add{ left =
   MemberExpr, right = LiteralExpr }`.
4. `var<uniform> u: array<vec3<f32>, lim.size>` → outer array size is
   `MemberExpr`, element type is `vec3<f32>` (nested template parse not
   regressed).
5. `var<uniform> u: array<f32, foo(0)>` → `CallExpr{ func =
   IdentExpr("foo"), args = [LiteralExpr(0)] }` — confirms the `(`
   postfix arm fires.
6. `var<uniform> u: array<f32, P.x[0].y>` → chained postfix:
   `MemberExpr( IndexExpr( MemberExpr(P,"x"), 0 ), "y" )`.
7. Negative: `var<uniform> u: vec2<P.x>` parses without crash (vec
   template arg accepts a type, so this should still error gracefully —
   assert error count > 0, no panic). Confirms the change is scoped to
   where template-arg-as-expr is used. Walk
   `parseTemplatedVec`/`parseTemplatedArray`/`parseTemplatedMat` to
   confirm only `array` and `mat` reach `parseTemplateArgExpr` for their
   N-args.
8. Smoke: minifier round-trip of a shader containing
   `array<f32, P.x>` produces output that re-parses identically
   (covered by the snapshot harness if a fixture is added; otherwise
   inline via `Minifier.run`).

**Add to** `tests/reflect_test.zig`:

9. The user's exact repro shape (Pair / `array<f32, P.x>`) →
   `elementCount = 4`, `totalSize = 16`. End-to-end assertion that the
   parser fix unblocks the existing Reflect const evaluator.
10. `array<f32, P.x + 1>` resolves to `elementCount = 5` — exercises
    BinaryExpr around the member.

**Edit** `tests/reflect_wgslreflect_test.zig`:

- Remove the `// PORT-DEFER: "alias struct" with array<Ship,
  a_bicycle.num_wheels>` line at
  `tests/reflect_wgslreflect_test.zig:607-608`.
- Port the wgsl_reflect "alias struct" test using the **direct**
  `array<Ship, a_bicycle.num_wheels>` shape (no intermediate
  `const bike_wheels` workaround).
- The existing `tests/reflect_test.zig:1534` "const member access on
  struct constructor" test — leave its workaround comments untouched
  per the constraint, but it is now redundant with the new direct
  re-port. Add a one-line note above it pointing to the new direct
  test.

**On `const2`:** the existing `tests/reflect_test.zig:1513` already
covers `radians`/`sin`/`u32` via intermediate consts and passes today.
The `// PORT-DEFER: "const2"` line at
`tests/reflect_wgslreflect_test.zig:609-610` claims the blocker is
"float builtins" — that's now stale (they're implemented).
**Recommended:** delete that PORT-DEFER line *and* add a direct re-port
using `array<vec4f, u32(sin(radians(90)) + 3)>` inline. The parser fix
is what unblocks the inline form. If the inline re-port reveals a
Reflect gap, fall back to keeping the PORT-DEFER and update its wording
to "needs inline-call template arg parser support — pending."

**Cross-check:** `bash tests/cross_check.sh` should still pass all 7
compute.toys shaders (none use member-in-template-arg today, but verify
no regression).

---

## 6. Commit breakdown

Atomic, conventional, in this order — each commit independently
buildable (`zig build && zig build wasm && zig build lsp && zig build
lsp-wasm`) and `zig build test` green.

1. **`refactor(parser): extract applyPostfixSuffixes from parsePostfixExpr`**
   No behavior change. Move the suffix loop body into the helper.
   `parsePostfixExpr` reduced to primary + helper call. Existing tests
   unchanged. Confirms CST output identical via snapshot tests.

2. **`fix(parser): support postfix .member/[idx]/(args) in template-arg expressions`**
   `parseTemplateUnaryExpr` calls `parseTemplatePostfixExpr` (new)
   instead of `parseTemplatePrimaryExpr`. `parseTemplatePostfixExpr`
   reuses `applyPostfixSuffixes`. ~10 LOC of parser change.

3. **`test(parser): cover postfix expressions in array<T,N> template args`**
   New `tests/parser_template_postfix_test.zig` with cases 1–8 above.

4. **`test(reflect): array<T, struct.member> resolves elementCount`**
   Add cases 9–10 to `tests/reflect_test.zig`. End-to-end repro
   coverage.

5. **`test(reflect): port wgsl_reflect "alias struct" without const workaround`**
   Edit `tests/reflect_wgslreflect_test.zig`: drop the "alias struct"
   PORT-DEFER line, add the direct re-port. Leave the workaround test
   in `reflect_test.zig` but cross-reference it.

6. *(optional, only if the inline form works end-to-end)*
   **`test(reflect): port wgsl_reflect "const2" with inline u32(sin(radians(90))+3)`**
   Drop the `const2` PORT-DEFER line; add the direct re-port. If the
   eval path reveals a gap, drop this commit and update the PORT-DEFER
   wording instead (separate commit).

---

## 7. Risks & cross-cutting checks

- **CST snapshot tests** — `tests/snapshot_test.zig` may exercise CST
  shapes; the refactor must produce byte-identical CST events. The
  helper's `cstOpenBefore(saved)` order must match the inline loop
  exactly.
- **Error recovery** — `parseTemplatePrimaryExprInner`'s `else` arm
  calls `addError` and `advance`. With postfix added, a trailing stray
  `.` after a successful primary now enters the helper; the helper's
  existing `else => addError("expected member name")` (line 1668)
  produces a sensible message. Verify by adding a malformed
  `array<f32, P.>` case and asserting a useful diagnostic.
- **`parseTemplatePrimaryExprInner`'s paren branch** stays restricted
  (`parseTemplateArgExpr`). Don't widen it in the same PR — it's a
  separate cleanup with different blast radius.
- **No submodule touches** — `external/wgsl_reflect` and `.gitmodules`
  stay staged untouched.
- **Test count expectation** — current 4171; +~10 for cases 1–10.

---

## 8. Out of scope (note for follow-up)

- Widening `parseTemplatePrimaryExprInner`'s `(...)` paren recursion to
  full `parseExpression`.
- Adding `.index` to Reflect.zig's `evalConst` (would make
  `array<f32, arr[0]>` resolvable, currently parser-only).
- Inline `@stride(N) array<…>` support (separate PORT-DEFER at
  `tests/reflect_wgslreflect_test.zig:558-563`).
