# Plan 05 — LSP validation-integration hardening

**Touches:** `lsp/handler/diagnostics.zig`, `lsp/handler/signature_help.zig`,
`lsp/handler/semantic_tokens.zig`, `lsp/handler/completion.zig`,
`lsp/handler/code_actions.zig`, `lsp/handler/hover.zig` (export one helper),
`src/options.zig` (one new LSP toggle spec), `CLAUDE.md` (module map).
No new files, no new packages.

**Status:** ready to execute. Verified against `main @ 363a71f`, 2026-08-05.

**Origin:** a deep-dive into "does the LSP use the validator properly and
thoroughly?" (this session) found the core wiring solid — full
`Validator.runPhases` on every keystroke, DCE/Liveness always computed,
incremental reparse correctly invalidates the analysis cache — but five
concrete gaps where handlers either bypass the validator's resolved data or
never surface real lint coverage. This plan fixes all five, in ascending
order of risk, plus a documentation gap.

---

## Verified current state (do not re-derive)

**Gap 1 — general lint packs never run over LSP.** `lsp/handler/diagnostics.zig:160-164`
hardcodes `wgslender.Linter.run(..., .{ .extends = &.{"@wgslender/minify"}, ... })`,
gated by `eff_minify.lintsActive()` (`src/MinifySettings.zig:116-118`: `mode == .strict
and lints.enabled`). The registry has five more packs — `@wgslender/recommended`,
`/style`, `/performance`, `/portability`, `/strict` (`src/lint/configs.zig:29,44,56,64,94`)
covering ~25 rules — that never run through the LSP in any configuration, because
this is the *only* `Linter.run` call site in `lsp/`. The irony: the config plumbing
to do this right **already exists and is already parsed** —
`Config.lint_extends`/`Config.lint_rules` (`src/Config.zig:49,54`) are populated from
`wgslender.json` into `handler.project_config` (`lsp/Handler.zig:55`, loaded via
`Config.discover`) *and* from the LSP client's `workspace/configuration` payload into
`handler.workspace_config` (`lsp/Handler.zig:60`, applied via `Config.applyJsonValue`
at `lsp/Handler.zig:371`) — it is simply never read by the diagnostics path. The CLI
already has the merge logic to copy: `Config.mergeLintOptions` (`src/Config.zig:209-246`,
precedence: config `lint_extends` first, then CLI/caller-supplied extends, falling back
to `@wgslender/recommended` when both are empty and `use_recommended` is set — this is
exactly how `wgslender lint` defaults to `@wgslender/recommended` per CLAUDE.md's Quick
Commands section). `appendLintRuleOverrides` (`lsp/Handler.zig:432-440`) already merges
project + workspace rule-severity overrides generically (any rule id, not just minify
ones) — it's *already correct*, just currently fed into a `Linter.run` call whose
`extends` list ignores those same two config layers.

**Gap 2 — `lsp/handler/signature_help.zig` barely touches validated data.**
- Builtins (line 54-56): only reads `builtin.min_args`/`max_args` to synthesize
  `"name(N..M args)"`. It ignores `Builtins.doc(name).signature` — the real
  WGSL-spec signature string (e.g. `"fn sin(e: T) -> T"`,
  `src/Builtins.zig:61-67`) — even though `lsp/handler/hover.zig:255-256`
  (`formatBuiltinHover`) already reads that exact field for the exact same
  builtins.
- User functions (line 87-107): re-derives the signature from raw AST
  `param.typ`/`f.return_type`, with a type-to-string `switch` that only
  handles `.ident`/`.vec`/`.mat` and falls back to a literal `"?"` for
  structs, arrays, pointers, atomics, and aliases — all of which the
  validator has already resolved to a concrete `Types.Type` sitting in
  `analysis.symbol_types`. `lsp/handler/hover.zig:213-248`
  (`formatFunctionSignature`) already does this correctly (reads
  `fn_type.parameters[pi].string()` off the resolved `Types.Function`) but is
  a private, unexported function in a different module.
- Cursor resolution (line 24-50) is a raw backward byte-scan over
  `doc.source` tracking paren depth and comma count, instead of the shared
  `NodeAtOffset` walker (`lsp/handler/node_at_offset.zig`) that hover/
  definition/references/call-hierarchy all use. Note: because WGSL forbids
  duplicate top-level function names (module-scope only, no nested `fn`),
  the *by-name* function lookup at line 71-72 is not actually a correctness
  bug the way the identical pattern is in completion/semantic-tokens (below)
  — it's the missing per-overload builtin data and the `"?"` type fallback
  that are the real thoroughness gaps here.

**Gap 3 — `lsp/handler/semantic_tokens.zig` resolves every identifier by
whole-module name match.** `resolveIdentSymbol` (line 295-310) has a
self-admitted approximation:
```
// For references, we need to walk the AST — too expensive for per-token resolution.
// Fall back to name-based lookup (less precise but reasonable for highlighting).
for (module.symbols.items) |sym| {
    if (std.mem.eql(u8, sym.original_name, name)) return sym;
}
```
Two symbols sharing a name in different scopes (a shadowed local, same-named
params in two different functions) get every occurrence tinted using
whichever symbol comes first in `module.symbols.items` — not the
lexically-correct one. The comment's stated reason ("too expensive") is
already solved elsewhere: `NodeAtOffset.find(module, offset)`
(`lsp/handler/node_at_offset.zig:29-35`) does exactly this per-offset lookup
for hover/definition/etc. and resolves through the AST's own `Ast.Ident.ref`
(scope-correct by construction, since `AstVisit` Pass 2 bound it), falling
back to `lookupSymbolByName` only for the narrow, documented case of unbound
attribute-arg idents (`node_at_offset.zig:37-40`).

**Gap 4 — `lsp/handler/completion.zig` has the same whole-module-by-name
defect in two places:**
- `memberCompletion` (line 67-111): resolves the base identifier's type via
  `for (module.symbols.items, 0..) |sym, idx| { if (eql(sym.original_name,
  base_name)) { base_type = analysis.symbol_types.get(idx); break; } }`
  (line 81-86) — same shadowing bug: `foo.` after a shadowed local can
  offer the wrong struct's fields.
- `generalCompletion` (line 113-151): lists **every** symbol in the entire
  module (all functions' parameters and locals from every function body),
  regardless of whether it's visible at the cursor. WGSL has no block-scoped
  globals and no hoisting (CLAUDE.md gotcha), so the only real scoping
  question is: which function (if any) contains the cursor, and which of
  that function's `let`/`var`/parameter declarations precede the cursor in
  textual order within an enclosing block. `Ast.CompoundStmt` already
  carries a byte-range `span` (`src/Ast.zig`, populated at
  `src/Parser.zig:1946`: `stmt.span = .{ .start = span_start, .end =
  self.prevTokenEnd() }`) for exactly this purpose — no new AST field is
  needed, just a walk of the enclosing function's compound-statement tree
  filtering by span containment and declaration order.

**Gap 5 (minor) — `lsp/handler/code_actions.zig`'s struct-insert-point quick
fix does text scanning.** `findStructBodyInsertPoint` (line 448-473) scans
`source` for a `struct <name> {` token sequence by hand instead of looking
up the struct's already-parsed declaration in `module.declarations`. Lower
severity — the surrounding code already labels this "best effort" (lines
406, 425) — but still a case of re-deriving from raw text what the parser
already resolved precisely.

**Gap 6 (docs) — CLAUDE.md's LSP module table is stale.** It lists only
`lsp/main.zig`, `lsp/wasm.zig`, `lsp/Handler.zig`, `lsp/handler/` — with no
entries for `lsp/wire/`, `lsp/native/`, `lsp/wasm/` (the subdirectory,
distinct from `lsp/wasm.zig`), `lsp/lspkit/`, `lsp/NativeServer.zig`, or
`lsp/Debouncer.zig`. The transport-split architecture has grown past the
documented map.

## Ground rules

- TDD reds-first: each block's test goes in first, run it, confirm the
  stated red, then implement to green.
- No CI. All commands are local (`zig build test`, `zig test ...`).
- One conventional, atomic commit per block. Do not commit unrelated
  working-tree changes (at plan-writing time `packages/rust/` has untracked
  in-progress work from a different task — leave it alone).
- **Verify the starting state before executing a block** — re-grep the cited
  line numbers first; this repo's line numbers rot between sessions.
- Fast red/green loop for `lsp/` handler files: `zig test src/root.zig` won't
  include `lsp/` — use `zig build test` (full suite) or, if a targeted LSP
  test file exists standalone, `zig test --dep wgslender -Mroot=<file>
  -Mwgslender=src/root.zig`. Confirm which applies per-block; `lsp/handler/*.zig`
  files have inline `test { ... }` blocks compiled as part of the `lsp` build
  target, not `tests/`.
- Full gate before each commit: `zig build && zig build wasm && zig build lsp
  && zig build lsp-wasm && zig build test`.

---

## Block 1 — General lint packs reach the LSP (Gap 1)

**Context recap:** `lsp/handler/diagnostics.zig`'s `validateDocumentInner`
(line 115-172) only ever runs `@wgslender/minify`, gated by
`eff_minify.lintsActive()`. `handler.project_config`/`handler.workspace_config`
already carry real `lint_extends`/`lint_rules` from `wgslender.json` and LSP
`workspace/configuration` — unread by this path.

1. **Red.** Add a test in `lsp/handler/diagnostics.zig`'s test block:
   open a document with an unused local variable that also triggers
   `no-unused-vars` from `@wgslender/recommended` (not `@wgslender/minify`),
   with the handler in default (non-strict-minify) mode. Call
   `validateDocumentFull`. Assert a diagnostic with a `no-unused-vars`-family
   code/message appears. Confirm this fails today (only the unused-var
   *validator* warning path — `Handler.appendUnusedWarnings` — may already
   catch it via a different code; pick a fixture where the **lint rule**
   specifically would fire something the validator's own unused-warning path
   does not, e.g. a `complexity` or `no-magic-numbers` violation from
   `@wgslender/recommended`/`@wgslender/style`, to prove the pack itself
   isn't running).
2. **Green — implement.** In `validateDocumentInner`:
   - Add a small helper (sibling to `buildMinifyRuleOverrides`) that computes
     the general `extends` list: `project_config.lint_extends ++
     workspace_config.lint_extends`, falling back to
     `&.{"@wgslender/recommended"}` when both are empty. Mirror
     `Config.mergeLintOptions`'s precedence comment style — don't call
     `mergeLintOptions` itself (it takes one `?Config` plus CLI-layer
     params that don't exist in the LSP; write the two-layer merge inline,
     same shape as `appendLintRuleOverrides`'s existing
     `inline for (.{ &self.project_config, &self.workspace_config })`
     pattern at `lsp/Handler.zig:437`).
   - When `eff_minify.lintsActive()`, append `"@wgslender/minify"` to that
     same list instead of running a second, separate `Linter.run` — one
     merged `extends` list, one `Linter.run` call, `overrides` unchanged
     (it already merges project+workspace rule severities generically, per
     Gap 1's note above — nothing there needs to change).
   - Keep the existing `include_minify_lints` cheap/full split, but rename
     its meaning precisely: general packs (cheap, no `MinifyEstimator`
     dependency) run in **both** `validateDocumentCheap` and
     `validateDocumentFull`; only the M0500-budget/estimator-dependent
     minify-pack behavior stays deferred to the full/debounced path. Update
     the doc comments at lines 37-42 and 47-52 to describe the new split
     accurately.
   - Add one new LSP toggle so users can opt out entirely: `lsp_lint_enabled`
     in `src/options.zig`'s `lsp_toggle_specs` (mirrors the existing
     `lsp_diagnostics_enabled` row exactly — `json_override = "lint.enabled"`,
     default `true`). Gate the new general-lint block on
     `handler.workspace_config.lsp_lint_enabled orelse
     handler.project_config.lsp_lint_enabled orelse true` (mirror the
     `diagnosticsEnabled()`-style accessor pattern already at
     `lsp/Handler.zig:407-410`).
3. Run the full gate. Confirm the new test is green and no existing
   diagnostics test regresses (re-run `lsp/handler/diagnostics.zig`'s
   existing `producePullReport`/`convertDiagnostic` tests — they must be
   unaffected since they use default settings, which now default to
   `@wgslender/recommended` running — check whether any of those fixtures
   *newly* trip a recommended-pack rule and adjust the fixture or assert
   the new diagnostic explicitly, whichever is correct for that test's intent).
4. Commit: `feat(lsp): surface configured lint packs in diagnostics, not just @wgslender/minify`

**⚠ Behavior change:** editors now receive `@wgslender/recommended`
diagnostics by default (previously: none, unless minify-strict mode was on).
This is the single biggest user-visible change in this plan — call it out
in the PR/commit body explicitly, and see the Behavior-changes table below.

---

## Block 2 — Signature help uses real signatures (Gap 2)

**Context recap:** `lsp/handler/signature_help.zig:54-56` shows only an
arity range for builtins; line 87-107 falls back to `"?"` for non-
ident/vec/mat parameter/return types. `lsp/handler/hover.zig:213-248`
(`formatFunctionSignature`) and `:251-290` (`formatBuiltinHover`) already
solve both problems correctly for the identical data.

1. **Red.** Add a test: signature help on a call to a builtin with a
   non-trivial signature (e.g. `clamp(` or `mix(`) asserts the label
   contains the real spec signature text (e.g. contains `"clamp"` and a
   `->` return-arrow, not just `"(2..3 args)"`). Add a second test: a
   user-defined function taking a struct parameter — assert the label
   shows the struct's real type name, not `"?"`. Confirm both fail today.
2. **Green.**
   - Export `formatFunctionSignature` from `hover.zig` (drop the leading
     lowercase-private convention — make it `pub fn formatFunctionSignature`,
     same signature) and call it from `signature_help.zig` for the
     user-function case, replacing lines 74-114's hand-rolled buffer logic.
     This automatically fixes the `"?"` fallback since `Types.Type.string()`
     (used internally) already handles every type kind.
   - For builtins, replace the arity-only label (lines 54-61) with
     `Builtins.doc(name)` when present (mirror `formatBuiltinHover`'s
     `d.signature` usage at `hover.zig:255-256`), falling back to the
     current arity-range synthesis only when `Builtins.doc(name)` returns
     null (verify whether every builtin has a doc row — `Builtins.zig`'s own
     test at line 1784-1806 asserts "every row carries overloads and
     documentation", so the fallback path may be dead code in practice;
     keep it anyway as a defensive default, but don't over-engineer it).
   - Leave the byte-scan cursor/enclosing-call resolution as is — per the
     Gap 2 note, `NodeAtOffset` doesn't support whitespace/comma cursor
     positions (its walk only matches identifiable tokens), so replacing it
     is a larger, separate undertaking not required to close this
     specific thoroughness gap. Note it as a candidate follow-up in the
     Behavior-changes/Not-done section instead.
3. Full gate. Commit: `feat(lsp): signature help uses real builtin/function signatures`

---

## Block 3 — Semantic tokens resolve via NodeAtOffset (Gap 3)

**Context recap:** `resolveIdentSymbol` (`semantic_tokens.zig:295-310`) does
a whole-module name scan for every identifier token. `NodeAtOffset.find`
already does scope-correct per-offset resolution.

1. **Red.** Write a fixture with two functions each declaring a local of the
   same name with different kinds (e.g. `fn a() { let x: f32 = 1.0; }` /
   `fn b() { var x: MyStruct; }`) where the *first* symbol in
   `module.symbols.items` is (by declaration order) the `f32` local from
   `a`, but the semantic token under test is the `x` reference *inside*
   `b`. Assert its emitted token type is `variable`/reflects the struct
   local, not misattributed to `a`'s. Construct the case carefully — pick a
   scenario where the wrong-symbol attribution is externally observable
   (e.g. one is a `parameter` and the other a `let`, so `SemanticTokenType`
   differs and the bug is visible in the emitted token-type, not just an
   internal detail). Confirm this reproduces the bug today (may need a
   `readonly`-modifier or token-type mismatch, since both `let`/`var` map to
   the same `variable` token type — favor a param-vs-local or const-vs-var
   pairing so the modifiers/type differ observably).
2. **Green.** Replace `resolveIdentSymbol`'s body with a call to
   `NodeAtOffset.find(module, tok_start)` (import `node_at_offset.zig`,
   already done indirectly via `Handler` in this package — add a direct
   import), matching on `.ident` (use `id.ref`), `.decl_name` (use
   `dn.sym_idx`), and `.type_ref` (use `tr.ref`) — falling through to
   `null`/unresolved for other variants (`.member_access`, `.binary_expr`,
   `.none` aren't reached here since this is called only for `.ident`-tag
   lexer tokens). Map the resolved `SymbolIndex` to `module.symbols.items[ref.index()]`
   when `ref.isValid()`.
   - **Flag the perf trade-off explicitly rather than assuming it's free:**
     `NodeAtOffset.find` walks `module.declarations.items` from scratch per
     call (`node_at_offset.zig:29-35`), so calling it once per identifier
     token is O(tokens × declarations) worst case, versus the current
     O(tokens × symbols). For most WGSL shaders (small files, this repo's
     own `tests/testdata/compute.toys/*` corpus) this is very unlikely to
     matter, but before committing, time `computeSemanticTokens` on the
     largest fixture available (check `tests/testdata/tint/` for the
     largest `.wgsl` file by line count) before/after and note the number in
     the commit body. If it regresses noticeably, memoize per-offset lookups
     are not needed (each token has a distinct offset) — instead consider
     caching the AST declaration whose span last matched, since consecutive
     tokens are usually in the same declaration (a simple "last decl" hint
     checked first before the full `find` scan).
3. Full gate. Commit: `fix(lsp): semantic tokens resolve identifiers via NodeAtOffset, not whole-module name match`

---

## Block 4 — Completion: member access resolves via NodeAtOffset (Gap 4a)

**Context recap:** `memberCompletion` (`completion.zig:67-111`) resolves the
base identifier's type by whole-module name scan (line 81-86). The
identifier's start offset (`start`, computed at line 69-71) is already
available — feed it straight to `NodeAtOffset.find`.

1. **Red.** Fixture: a local named `p` shadowing a global-scope `p` (or two
   functions each with a same-named local `p` of a different struct type),
   where dot-completion after the *shadowing* local's `p.` should offer the
   shadowing local's fields, not the outer/other one's. Confirm today's
   whole-module-first-match returns the wrong field set.
2. **Green.** In `memberCompletion`, replace the `for (module.symbols.items,
   0..)` scan (line 81-86) with `NodeAtOffset.find(module, start)`, matching
   `.ident` → `id.ref` (skip if `!ref.isValid()`), then
   `analysis.symbol_types.get(ref.index())` as before. Import
   `node_at_offset.zig` in `completion.zig`.
3. Full gate. Commit: `fix(lsp): member completion resolves base type via NodeAtOffset, not whole-module name match`

---

## Block 5 — Completion: scope-aware general completion (Gap 4b)

**Context recap:** `generalCompletion` (`completion.zig:113-151`) lists
every symbol in the whole module. WGSL has no block-scoped globals and no
hoisting, so correct scoping only requires: (a) module-level decls, always
visible; (b) if the cursor is inside a function, that function's
parameters plus any `let`/`var` declared in an enclosing block that
textually precedes the cursor. `Ast.CompoundStmt.span` (populated at
`src/Parser.zig:1946`) already carries the byte range needed for (b) — no
new AST field required. This is the highest-effort block in this plan;
budget it its own session.

1. **Red.** Fixture: `fn a() { let x = 1.0; } fn b() { /* cursor here, no x in scope */ }`
   — general completion inside `b`'s empty body must **not** offer `x`
   (from `a`'s body). Add a second case: `fn c() { let y = 1.0; if (true) { /* cursor here */ } }`
   — completion inside the `if` body **must** offer `y` (outer-block
   visibility into a nested block). Confirm both are observable today
   (first case fails — `x` incorrectly offered; second already passes,
   confirm it stays green).
2. **Green.**
   - Add a helper (new private fn in `completion.zig` or a small addition to
     `node_at_offset.zig` if it fits that module's charter better — check
     which is a better fit at implementation time) that, given `module` and
     `offset`: finds the enclosing `.function` declaration whose body's
     `span` contains `offset` (iterate `module.declarations.items`,
     `decl.function.body.span`); if none, return null (top-level — no
     locals to add).
   - Within that function, walk the `CompoundStmt` tree starting at
     `f.body`, descending into the single nested compound whose `.span`
     contains `offset` at each level (an `.if`/`.for`/`.while`/`.loop`/
     `.switch` statement's body/case bodies are each their own
     `CompoundStmt` — descend into whichever nested one (if any) contains
     `offset`, otherwise stop at the current level). At each level visited
     (outer to inner, inclusive), collect symbols from `Stmt.decl` entries
     (`let`/`var` cases — reuse the same `Ast.Decl` handling
     `node_at_offset.zig:129-137` already pattern-matches) whose own `loc`
     is `<= offset` (textual order, no hoisting).
   - Always include the function's own parameters (`f.parameters.items`)
     regardless of offset (a parameter is visible for the entire body).
   - Feed the resulting symbol set into `generalCompletion` alongside (not
     instead of) the existing module-level symbols loop (line 120-131) —
     module-level symbols stay unconditional; only the *local* half of that
     loop becomes scope-filtered. The cleanest split: change the existing
     loop at line 120 to skip `.parameter`/`.let`/`.@"var"`-kind symbols
     unless they're in the locally-computed visible set (module-level
     `.function`/`.@"struct"`/`.@"const"`/`.override` symbols pass through
     unconditionally, matching current behavior for top-level things).
3. Full gate — this block touches a recursive walk, so add a couple of
   extra fixtures for `for`-loop init-scope and `switch`-case-body nesting,
   since those are the least common nested-compound shapes.
4. Commit: `fix(lsp): general completion is scope-aware for locals (no cross-function/pre-declaration leakage)`

**Behavior change:** completion inside a function body will offer *fewer*
items than before (locals from *other* functions and not-yet-declared
locals in the *same* function disappear) — this is a correctness fix,
called out because it's user-visible (fewer, more relevant suggestions).

---

## Block 6 — Code action: struct insert-point via AST (Gap 5, minor)

**Context recap:** `findStructBodyInsertPoint` (`code_actions.zig:448-473`)
scans `source` text for `struct <name> {`. The struct's declaration
(including its members and their spans) is already sitting in
`module.declarations`.

1. **Red.** A test with a struct whose name appears as a *substring inside a
   comment or another identifier* before the real declaration (e.g. a
   comment mentioning `// see MyStruct` before `struct MyStruct { ... }`) —
   confirm the current text-scan either mis-locates the insert point or
   already happens to handle it via its "hand-rolled word-boundary checks"
   (re-verify at implementation time; if the current checks already handle
   this specific case correctly, pick a fixture that demonstrably breaks it
   — e.g. a struct name that's a prefix of another struct's name declared
   earlier in the file — before writing the red).
2. **Green.** Look up the target struct in `module.declarations` directly
   (match `.@"struct"` where the symbol's `original_name` equals
   `type_name`), and use its members' last field span / struct decl's
   `decl_span` end to compute the insert point, replacing the text scan
   entirely.
3. Full gate. Commit: `fix(lsp): struct insert-point quick fix looks up the AST declaration, not source text`

---

## Block 7 — Docs: update the LSP module map (Gap 6)

1. In `CLAUDE.md`'s Module Map table, add rows for `lsp/wire/`, `lsp/native/`,
   `lsp/wasm/` (the subdirectory), `lsp/lspkit/`, `lsp/NativeServer.zig`,
   `lsp/Debouncer.zig` — one line each, purpose derived from reading each
   directory's file headers (they weren't researched line-by-line for this
   plan; skim each directory's doc comments to write an accurate one-liner
   rather than guessing from the name alone).
2. No code changes, no gate beyond a sanity read-through.
3. Commit: `docs: add lsp/wire, lsp/native, lsp/wasm, lsp/lspkit, NativeServer, Debouncer to the module map`

---

## Behavior changes (explicit — per repo feedback convention)

| Change | Kind | Runtime effect |
|---|---|---|
| Block 1: `@wgslender/recommended` (or configured packs) now run over LSP by default | New diagnostics surfaced in editors | Users see new warnings they didn't before; opt-out via new `lint.enabled: false` LSP setting |
| Block 1: new `lsp_lint_enabled` / `lint.enabled` LSP setting | New config surface (`src/options.zig`) | Additive; default `true` preserves Block 1's new behavior unless explicitly disabled |
| Block 5: general completion no longer lists other functions' locals or not-yet-declared same-function locals | Fewer completion items in some contexts | Correctness fix; no wire-format change, only item-count/content |

**Explicitly not done** (candidate follow-ups, each its own decision):
extending `NodeAtOffset` to support whitespace/comma cursor positions so
signature help can use it too (Block 2 keeps the byte-scan); per-overload
signature disambiguation in signature help using `Overload.resolve` against
already-typed argument expressions; a `for`-loop init-statement's implicit
scope was folded into the "single nested compound" walk in Block 5 rather
than special-cased — re-check `Stmt.for`'s `init_stmt` handling specifically
if a fixture surfaces a gap there.

## Definition of done

- [ ] All seven blocks committed, each atomic and conventional.
- [ ] `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
      zig build test` green after every block.
- [ ] `@wgslender/recommended` diagnostics visible over LSP by default
      (Block 1), with a working `lint.enabled: false` opt-out.
- [ ] Signature help shows real builtin spec signatures and real
      struct/array/pointer/atomic parameter types (Block 2).
- [ ] Semantic tokens, member completion, and general completion all resolve
      through scope-correct AST data, not whole-module name matching
      (Blocks 3-5).
- [ ] `CLAUDE.md`'s LSP module map lists every subdirectory under `lsp/`
      (Block 7).
- [ ] No CI files added; every test entry point remains a local, on-demand
      command.
