# Plan 05 — LSP validation-integration hardening

**Touches:** `lsp/handler/diagnostics.zig`, `lsp/handler/signature_help.zig`,
`lsp/handler/semantic_tokens.zig`, `lsp/handler/completion.zig`,
`lsp/handler/code_actions.zig`, `lsp/handler/hover.zig` (export one helper),
`lsp/handler/unused_warnings.zig` (Block 1 dedup), `src/options.zig` +
`src/Config.zig` (one new LSP toggle spec **and** its backing field),
`npm/wgslender-vscode/package.json` (surface the new toggle),
`tests/{completion,signature_help,semantic_tokens}_test.zig`,
`CLAUDE.md` (module map). No new files, no new packages.

**Status:** ready to execute, **after the environment prep below**.
Originally verified against `main @ 363a71f`; re-verified 2026-08-05 against
worktree `worktree-lsp-work @ 017cb1d` (= `origin/main`). `git diff 363a71f
017cb1d -- lsp/ src/` is only `src/Compiler.zig` + `CLAUDE.md`, so every code
citation below applies unchanged to either baseline. Note `origin/main` is 9
commits *behind* local `main`, which additionally carries the
`npm/wgslender` → `packages/js-npm` move and the `packages/rust` work —
neither is touched by this plan.

**Origin:** a deep-dive into "does the LSP use the validator properly and
thoroughly?" found the core wiring solid — full `Validator.runPhases` on
every keystroke, DCE/Liveness always computed, incremental reparse correctly
invalidates the analysis cache — but six concrete gaps where handlers either
bypass the validator's resolved data or never surface real lint coverage.

**Revision note (2026-08-05 review pass):** a verification pass re-grepped
every citation and *empirically probed* the two riskiest assumptions against
the live handler. Findings folded in below. The headline corrections:
**Block 4 was unsound as originally written** (disproven by probe — see the
block), **Block 1 was missing a duplicate-diagnostic problem** that expands
its scope, and **five of the seven proposed red fixtures did not reproduce
the bug they targeted**. Every correction is marked `⚠ CORRECTED` so a
reader who saw the earlier draft can diff quickly.

---

## Environment prep (do this first — the gate cannot run without it)

`⚠ CORRECTED — this section is new.`

If executing in a fresh worktree (e.g. `.claude/worktrees/lsp-work`):

1. `external/lsp-kit/` is **empty** in a fresh worktree. `build.zig.zon`
   declares `.lsp_kit = .{ .path = "external/lsp-kit", .lazy = true }`, so
   `zig build lsp` panics with `unable to find module 'lsp'` — and
   `zig build lsp-wasm` and `zig build test` fail the same way, because the
   LSP handler tests are wired into the default test step. Populate it from
   the primary checkout (`rsync -a /Users/hugo/Dev/wgslender/external/lsp-kit/
   external/lsp-kit/`) before attempting any block's gate.
2. `tests/testdata/tint` is likewise absent. All corpus tests self-skip when
   it's missing, which is fine for this plan (no block touches the goldens) —
   but it means a green `zig build test` here is *not* the same gate as a
   green one in the primary checkout. Symlink it if you want full coverage.
3. `plans/` does not exist on `origin/main`, so this file was added to the
   worktree branch. Reconcile with the copy on local `main` when merging.

## Verified current state (do not re-derive)

**Gap 1 — general lint packs never run over LSP.** `lsp/handler/diagnostics.zig:160-164`
hardcodes `wgslender.Linter.run(..., .{ .extends = &.{"@wgslender/minify"}, ... })`,
gated by `options.include_minify_lints and eff_minify.lintsActive()`
(`src/MinifySettings.zig:116-118`: `mode == .strict and lints.enabled`). The
registry has five more packs — `@wgslender/recommended`, `/style`,
`/performance`, `/portability`, `/strict` (`src/lint/configs.zig:29,44,56,64,94`)
covering 24 distinct non-minify rule ids — that never run through the LSP in
any configuration, because this is the *only* `Linter.run` call site in
`lsp/` (verified by grep). The irony: the config plumbing to do this right
**already exists and is already parsed** — `Config.lint_extends`/`Config.lint_rules`
(`src/Config.zig:49,54`) are populated from `wgslender.json` into
`handler.project_config` (`lsp/Handler.zig:55`, loaded via `Config.discover`)
*and* from the LSP client's `workspace/configuration` payload into
`handler.workspace_config` (`lsp/Handler.zig:60`, applied via
`Config.applyJsonValue` at `lsp/Handler.zig:371`) — it is simply never read
by the diagnostics path. The CLI already has the merge logic to copy:
`Config.mergeLintOptions` (`src/Config.zig:219`, doc comment from 202;
precedence: config `lint_extends` first, then CLI/caller-supplied extends,
falling back to `@wgslender/recommended` when both are empty and
`use_recommended` is set). `appendLintRuleOverrides` (`lsp/Handler.zig:432-440`)
already merges project + workspace rule-severity overrides generically (any
rule id, not just minify ones) — it's *already correct*, just currently fed
into a `Linter.run` call whose `extends` list ignores those same two config
layers.

**Gap 1b — `⚠ CORRECTED, NEW`: the three recommended-pack rules the LSP
already emits by hand.** `@wgslender/recommended` contains `no-unused-vars`,
`no-dead-code`, and `no-unused-binding` (`src/lint/configs.zig:32-34`). The
LSP **already** emits exactly those three, unconditionally, from hand-coded
passes at `lsp/handler/diagnostics.zig:132-134` →
`lsp/handler/unused_warnings.zig`, which hardcode codes `"W0001"` (line 37),
`"W0002"` (line 75), `"W0003"` (line 103). The lint rules emit the *same
codes* off the *same predicate*: `src/lint/rules/no_unused_vars.zig:4-9` says
verbatim that it "supersedes the hand-coded `Handler.appendUnusedWarnings`
previously in `lsp/Handler.zig`. The code (`W0001`), message shape, [...]
Filtering mirrors the original hand-coded pass"; `no_unused_binding.zig:10-11`
says "Preserves the shape of the hand-coded LSP `appendUnusedBindingWarnings`:
same W0003 code, same filter, same message." Both consult
`analysis.isUnusedReportable` — the same function `unused_warnings.zig:24`
calls. **Consequence: turning on `@wgslender/recommended` without removing
the hand-coded passes doubles every unused/dead-code/unused-binding warning
in the editor** — identical code, range, and message, twice. Block 1 must
resolve this; see its step 2c.

**Gap 2 — `lsp/handler/signature_help.zig` barely touches validated data.**
- Builtins (line 54-56): only reads `builtin.min_args`/`max_args` to synthesize
  `"name(N..M args)"`. It ignores the real WGSL-spec signature string (e.g.
  `"fn sin(e: T) -> T"`), even though `lsp/handler/hover.zig:255-256`
  (`formatBuiltinHover`) already reads that exact field for the exact same
  builtins. `⚠ CORRECTED:` `Builtins.lookup` (`src/Builtins.zig:127`) returns a
  `Builtin` that **already carries a `.doc` field** — so the fix is
  `builtin.doc.signature`, not a second `Builtins.doc(name)` map lookup.
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
  `NodeAtOffset` walker (`lsp/handler/node_at_offset.zig`). Note: because
  WGSL forbids duplicate top-level function names, the *by-name* function
  lookup at line 71-72 is not a correctness bug the way the identical
  pattern is in completion/semantic-tokens — it's the missing builtin
  signature data and the `"?"` type fallback that are the real gaps here.
- `⚠ CORRECTED, pre-existing latent bug:` line 86 does
  `module.symbols.items[param.name.index()]` with **no `param.name.isValid()`
  guard** — an out-of-bounds index on a parameter whose symbol failed to
  bind. `hover.zig:234` has the identical unguarded access. Guard both while
  in the area (Block 2).

**Gap 3 — `lsp/handler/semantic_tokens.zig` resolves identifiers by
whole-module name match.** `resolveIdentSymbol` (line 295-310):

```zig
fn resolveIdentSymbol(module: *const Ast.Module, loc: u32, name: []const u8) ?Ast.Symbol {
    // Search symbols for one matching this location and name
    for (module.symbols.items) |sym| {
        if (sym.original_name.len == 0) continue;
        if (std.mem.eql(u8, sym.original_name, name)) {
            // For declarations, loc matches exactly
            if (sym.loc == loc) return sym;
        }
    }
    // For references, we need to walk the AST — too expensive for per-token resolution.
    // Fall back to name-based lookup (less precise but reasonable for highlighting).
    for (module.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.original_name, name)) return sym;
    }
    return null;
}
```

`⚠ CORRECTED — the bug is narrower than originally stated.` The **first**
loop is an exact `sym.loc == loc` match, so *declaration sites already
resolve correctly*. Only **references** fall through to the name-based second
loop and get whichever same-named symbol comes first in
`module.symbols.items` — not the lexically-correct one. Any red fixture must
therefore target a reference, not a declaration. The comment's stated reason
("too expensive") is already solved elsewhere: `NodeAtOffset.find(module,
offset)` (`node_at_offset.zig:29-35`) does exactly this per-offset lookup for
hover/definition/etc. and resolves through the AST's own `Ast.Ident.ref`
(scope-correct by construction, since `AstVisit` Pass 2 bound it), falling
back to `lookupSymbolByName` only for the narrow, documented case of unbound
attribute-arg idents (`node_at_offset.zig:37-48`).

**Gap 4 — `lsp/handler/completion.zig` has the same whole-module-by-name
defect in two places:**
- `memberCompletion` (line 67-111): resolves the base identifier's type via
  `for (module.symbols.items, 0..) |sym, idx| { if (eql(sym.original_name,
  base_name)) { base_type = analysis.symbol_types.get(idx); break; } }`
  (line 81-86) — same shadowing bug: `foo.` after a shadowed local can
  offer the wrong struct's fields. `⚠ CORRECTED:` but see Block 4 — the
  obvious fix regresses the common case. There are currently **zero** tests
  for the `.` trigger path in `tests/completion_test.zig`.
- `generalCompletion` (line 113-151): lists **every** symbol in the entire
  module (all functions' parameters and locals from every function body),
  regardless of whether it's visible at the cursor. WGSL has no block-scoped
  globals and no hoisting (CLAUDE.md gotcha), so the only real scoping
  question is: which function (if any) contains the cursor, and which of
  that function's `let`/`var`/parameter declarations precede the cursor in
  textual order within an enclosing block. `Ast.CompoundStmt` already
  carries a byte-range `span` (`src/Ast.zig:1077-1080`, populated at
  `src/Parser.zig:1946`: `stmt.span = .{ .start = span_start, .end =
  self.prevTokenEnd() }`) — no new AST field is needed.

**Gap 5 (minor) — `lsp/handler/code_actions.zig`'s struct-insert-point quick
fix does text scanning.** `findStructBodyInsertPoint` (line 448-480+) scans
`source` for a `struct <name> {` token sequence by hand. `⚠ CORRECTED:` the
existing scan is more robust than the original draft assumed — it *does*
enforce word boundaries on `struct` (lines 455-458) and matches the name with
exact `std.mem.eql` (line 470). See Block 6 for the fixture that actually
breaks it, and for two API facts that invalidate the original green step.

**Gap 6 (docs) — CLAUDE.md's LSP module table is stale.** It lists only
`lsp/main.zig`, `lsp/wasm.zig`, `lsp/Handler.zig`, `lsp/handler/`
(`CLAUDE.md:125-128`) — with no entries for `lsp/wire/`, `lsp/native/`,
`lsp/wasm/` (the subdirectory, distinct from `lsp/wasm.zig`), `lsp/lspkit/`,
`lsp/NativeServer.zig`, `lsp/Debouncer.zig`, and — `⚠ CORRECTED, also
missing` — `lsp/uri.zig`, `lsp/lspkit_root.zig`, `lsp/wire_root.zig`.

## Ground rules

- TDD reds-first: each block's test goes in first, run it, confirm the
  stated red, then implement to green.
- No CI. All commands are local (`zig build test`, `zig test ...`).
- One conventional, atomic commit per block.
- **Verify the starting state before executing a block** — re-grep the cited
  line numbers first; this repo's line numbers rot between sessions.
- `⚠ CORRECTED — test locations.` The original rule ("`lsp/handler/*.zig`
  files have inline `test { ... }` blocks compiled as part of the `lsp` build
  target, not `tests/`") is true only for `diagnostics.zig` (11 inline tests)
  and `code_actions.zig` (18). The three files Blocks 2–5 target have
  **zero** inline tests and each has a dedicated, already-wired test file:
  - `tests/completion_test.zig` (`build.zig:587`)
  - `tests/signature_help_test.zig` (`build.zig:588`)
  - `tests/semantic_tokens_test.zig` (`build.zig:796`)

  Each is built by `addTestStep` with imports `{ wgslender, Handler }` and
  follows a `setup(source)` / `teardown(ctx)` pattern
  (`tests/completion_test.zig:1-21`). Put Blocks 2–5's reds there. Fast
  standalone loop:
  ```
  zig test --dep wgslender --dep Handler \
    -Mroot=tests/completion_test.zig \
    -Mwgslender=src/root.zig \
    --dep wgslender -MHandler=lsp/Handler.zig
  ```
  (verified working; substitute the test file per block). Blocks 1 and 6 add
  inline tests to `diagnostics.zig` / `code_actions.zig` as before and need
  the full `zig build test`.
- Full gate before each commit: `zig build && zig build wasm && zig build lsp
  && zig build lsp-wasm && zig build test` — after the environment prep above.

## Suggested order

`⚠ CORRECTED — the original ascending-risk claim was inverted.` Block 1 is
the **highest**-risk block, not the lowest: it carries a scope expansion
(Gap 1b dedup), a new config surface, and the plan's only user-visible
default change. Recommended order: **7 → 2 → 3 → 6 → 4 → 5 → 1**, or simply
start with 7 and 2 if you want an easy first commit. The blocks are
independent; nothing below depends on Block 1 landing first.

---

## Block 1 — General lint packs reach the LSP (Gap 1 + Gap 1b)

**Context recap:** `validateDocumentInner` (line 115-172) only ever runs
`@wgslender/minify`. `handler.project_config`/`handler.workspace_config`
already carry real `lint_extends`/`lint_rules` — unread by this path. And
three rules in `@wgslender/recommended` duplicate hand-coded LSP passes
(Gap 1b).

1. **Red.** Add a test in `lsp/handler/diagnostics.zig`'s test block: open a
   document that violates a rule which is in `@wgslender/recommended` **and**
   has no hand-coded LSP equivalent, with the handler in default
   (non-strict-minify) mode. Call `validateDocumentFull` and assert the
   diagnostic appears.
   - `⚠ CORRECTED — rule choice.` The original draft suggested
     `no-magic-numbers` or `complexity`. **`no-magic-numbers` is in no pack
     at all** (opt-in only — `src/lint/configs.zig:92` calls it "typically
     noisy"), and **`complexity` is only in `@wgslender/strict`**
     (`configs.zig:119`). Neither is in `recommended` or `style`, so neither
     would go green. Pick from `recommended`'s actual roster
     (`configs.zig:32-40`), excluding the three Gap-1b duplicates:
     `no-unreachable`, `no-constant-condition`, `for-direction`,
     `no-duplicate-case`, `no-self-assign`, `no-redundant-casts`.
     `no-self-assign` (`x = x;`) or `no-constant-condition` (`if (true) {}`)
     make the tightest fixtures.
2. **Green — implement.** In `validateDocumentInner`:
   - **(a) Merged extends list.** Add a small helper (sibling to
     `buildMinifyRuleOverrides`) that computes the general `extends` list:
     `project_config.lint_extends ++ workspace_config.lint_extends`, falling
     back to `&.{"@wgslender/recommended"}` when both are empty. Don't call
     `Config.mergeLintOptions` itself (it takes one `?Config` plus CLI-layer
     params that don't exist in the LSP) — write the two-layer merge inline,
     same shape as `appendLintRuleOverrides`'s existing
     `inline for (.{ &self.project_config, &self.workspace_config })` pattern
     at `lsp/Handler.zig:437`. When `eff_minify.lintsActive()`, append
     `"@wgslender/minify"` to that same list instead of running a second,
     separate `Linter.run` — one merged `extends` list, one `Linter.run`
     call. `overrides` is unchanged (it already merges project + workspace
     rule severities generically).
   - **(b) Cheap/full split.** Keep the existing `include_minify_lints`
     split but rename its meaning precisely: general packs (cheap, no
     `MinifyEstimator` dependency) run in **both** `validateDocumentCheap`
     and `validateDocumentFull`; only the M0500-budget/estimator-dependent
     minify-pack behavior stays deferred to the full/debounced path. Update
     the doc comments at lines 37-42 and 47-52 to describe the new split
     accurately.
   - **(c) `⚠ CORRECTED, NEW` — resolve the W0001/W0002/W0003 duplication.**
     Once `@wgslender/recommended` runs, `no-unused-vars`/`no-dead-code`/
     `no-unused-binding` emit the same codes at the same ranges as the
     hand-coded passes at lines 132-134. **Delete those three calls and let
     the lint rules own the diagnostics** — this is what
     `src/lint/rules/no_unused_vars.zig:4` documents as the intent
     ("supersedes the hand-coded `Handler.appendUnusedWarnings`"), and the
     rules read the same `analysis.isUnusedReportable` predicate, so output
     is byte-identical *when the pack is active*.
     - Gate it correctly: the hand-coded passes today run **unconditionally**,
       including when the user has set `extends: ["@wgslender/style"]` (no
       unused rules) or disabled lint entirely via the new toggle from step
       (d). Dropping them wholesale would silently remove W0001-W0003 in
       those configurations. Choose one and state it in the commit body:
       either (i) keep the hand-coded passes **only** when the resolved
       `extends` list does not pull in the corresponding rule, or (ii) accept
       that these three warnings become lint-pack-governed and document the
       behavior change. **(ii) is the cleaner design and matches the rules'
       stated intent** — prefer it unless the fixture work says otherwise.
     - Either way, add a regression test asserting exactly **one** W0001 for
       a single unused local under default settings. This is the test that
       proves the dedup; write it as part of this block's red.
     - `lsp/handler/unused_warnings.zig` and its three `append*` exports on
       `Handler` may become dead after (ii) — remove them in the same commit
       if so, and check `tests/lint_warnings_test.zig` /
       `tests/lsp_pull_diagnostic_test.zig` for callers first.
   - **(d) New opt-out toggle.** Add `lsp_lint_enabled`:
     - `src/options.zig`'s `lsp_toggle_specs` (line 892-895), mirroring the
       `lsp_diagnostics_enabled` row: `.kind = .bool_opt, .cli_simple =
       false, .json_override = "lint.enabled"`.
     - `⚠ CORRECTED — also required:` the backing field
       `lsp_lint_enabled: ?bool = null` on `src/Config.zig` (next to
       `lsp_diagnostics_enabled` at line 68). `Config.zig:31` runs
       `options.assertSpecFieldsExist(Config, &options.lsp_toggle_specs)` at
       comptime — **the build fails without it.** Parsing is then automatic
       via `applyJsonValue`'s nested-`lsp`-object branch (`Config.zig:120-123`).
     - Gate the new general-lint block on
       `handler.workspace_config.lsp_lint_enabled orelse
       handler.project_config.lsp_lint_enabled orelse true`, mirroring the
       `diagnosticsEnabled()` accessor at `lsp/Handler.zig:407-410`.
     - `⚠ CORRECTED — zig build gen-npm is NOT needed.` `tools/gen_npm.zig:92`
       iterates `options.minifier_options_specs` only; `lsp_toggle_specs`
       never reaches `configs.js`/`configs.d.ts`, so
       `tests/npm_generated_test.zig` won't drift.
     - `⚠ CORRECTED — do add` a `wgslender.lsp.lint.enabled` entry to
       `npm/wgslender-vscode/package.json` (alongside
       `wgslender.lsp.diagnostics.enabled` at line 110), or the toggle is
       undiscoverable from the VS Code settings UI.
3. Run the full gate. Re-run `diagnostics.zig`'s existing
   `producePullReport`/`convertDiagnostic` tests — check whether any fixture
   *newly* trips a recommended-pack rule and adjust the fixture or assert the
   new diagnostic explicitly, whichever is correct for that test's intent.
4. Commit: `feat(lsp): surface configured lint packs in diagnostics, not just @wgslender/minify`

**⚠ Behavior change:** editors now receive `@wgslender/recommended`
diagnostics by default (previously: none, unless minify-strict mode was on),
and — per step 2c option (ii) — W0001/W0002/W0003 become governed by the
lint config instead of always-on. Both are the biggest user-visible changes
in this plan; call them out in the commit body and see the table below.

---

## Block 2 — Signature help uses real signatures (Gap 2)

**Context recap:** `signature_help.zig:54-56` shows only an arity range for
builtins; lines 87-107 fall back to `"?"` for non-ident/vec/mat types.
`hover.zig:213-248` (`formatFunctionSignature`) and `:251-290`
(`formatBuiltinHover`) already solve both for the identical data.

1. **Red.** In `tests/signature_help_test.zig` (`⚠ CORRECTED` — not an
   inline test block): signature help on a call to a builtin with a
   non-trivial signature (e.g. `clamp(` or `mix(`) asserts the label
   contains the real spec signature text (contains `"clamp"` and a `->`
   return-arrow, not just `"(2..3 args)"`). Second test: a user-defined
   function taking a struct parameter — assert the label shows the struct's
   real type name, not `"?"`. Confirm both fail today.
2. **Green.**
   - Export `formatFunctionSignature` from `hover.zig` (make it `pub`, same
     signature) and call it from `signature_help.zig` for the user-function
     case.
   - `⚠ CORRECTED — this is not the drop-in replacement the original draft
     described.` Two things the original missed:
     - `formatFunctionSignature(buf, module, sym_idx, fn_type)` takes a
       **resolved** `*const wgslender.Types.Function`. `signature_help.zig`
       does not currently fetch one — add the `hover.zig:55-58` lookup:
       `analysis.symbol_types.get(sym_idx.index())`, check `t == .function`,
       pass `t.function`. Keep the existing hand-rolled buffer path as the
       fallback for when the type didn't resolve (parse errors) or
       `formatFunctionSignature` returns `null` (decl not found).
     - It returns **only the label**. `SignatureInfo.parameters` (the
       per-parameter name slice, allocated at line 80) still needs its own
       loop — so lines 74-114 shrink, they don't disappear.
   - For builtins, replace the arity-only label (lines 54-61) with the spec
     signature. `⚠ CORRECTED:` use `builtin.doc.signature` off the `Builtin`
     that `Builtins.lookup` already returned — no second `Builtins.doc(name)`
     call needed. Keep the arity-range synthesis as a defensive fallback for
     an empty signature, but note it is effectively dead: the invariant test
     at `src/Builtins.zig:1784-1806` ("every row carries overloads and
     documentation") asserts `b.doc.signature.len != 0` for every entry,
     `bitcast` included.
   - `⚠ CORRECTED, drive-by:` guard `param.name.isValid()` before
     `module.symbols.items[param.name.index()]` at `signature_help.zig:86`
     **and** `hover.zig:234` — both are unguarded today and index
     out-of-bounds on an unbound parameter symbol.
   - Leave the byte-scan cursor/enclosing-call resolution as is — per Gap 2,
     `NodeAtOffset` doesn't support whitespace/comma cursor positions, so
     replacing it is a separate undertaking. Noted in Not-done below.
3. Full gate. Commit: `feat(lsp): signature help uses real builtin/function signatures`

---

## Block 3 — Semantic tokens resolve via NodeAtOffset (Gap 3)

**Context recap:** `resolveIdentSymbol` (`semantic_tokens.zig:295-310`) falls
back to a whole-module name scan for every *reference* token (declarations
already resolve exactly by `loc`). `NodeAtOffset.find` does scope-correct
per-offset resolution.

1. **Red** (in `tests/semantic_tokens_test.zig`).
   `⚠ CORRECTED — the original fixture would not have reproduced the bug,
   for two independent reasons.` (a) It used `var x: MyStruct;` as the token
   under test, which is a **declaration** — the exact-`loc` first loop
   resolves those correctly already. (b) It paired `let` against `var`, but
   the token-type switch at `semantic_tokens.zig:186-191` maps **both** to
   `SemanticTokenType.variable`, so the misattribution would be invisible.

   Use a **parameter-vs-local** pairing and target a **reference**:
   ```wgsl
   fn a(x: f32) -> f32 { return x; }
   fn b() { let x = 1.0; let y = x; }
   //                              ^ token under test — a reference
   ```
   `a`'s parameter `x` precedes `b`'s local in `module.symbols.items`, so the
   name-scan fallback returns it, and the reference in `b` is emitted as
   `SemanticTokenType.parameter` instead of `variable`. That difference is
   externally observable in the token stream. Confirm the red.
2. **Green.** Replace `resolveIdentSymbol`'s body with a call to
   `NodeAtOffset.find(module, tok_start)` (add a direct import of
   `node_at_offset.zig`), matching:
   - `.ident` → `id.ref`
   - `.decl_name` → `dn.sym_idx`
   - `.type_ref` → `tr.ref`
   - `⚠ CORRECTED — .member_access → ma.ref.` The original draft said
     `.member_access` "isn't reached here since this is called only for
     `.ident`-tag lexer tokens". **That is false**: the member name in
     `s.field` *is* an `.ident` lexer token, and `node_at_offset.zig:260-266`
     returns `.member_access` for it. Today the name-scan resolves it to a
     `.member`-kind symbol (`Ast.Symbol.Kind.member`, `src/Ast.zig:129`),
     which the switch's `else` arm colors as `variable`. Falling through to
     `null` would **drop member-name coloring entirely** — a visible
     regression. Map it: `ma.ref` is populated by the validator at
     `src/validator/Expressions.zig:2067`, and the LSP always runs
     validation, so it resolves in the normal case. Fall through to `null`
     only when `!ref.isValid()`.

   Map the resolved `SymbolIndex` to `module.symbols.items[ref.index()]` when
   `ref.isValid()`. `.binary_expr` and `.none` fall through to `null`.
   - **`⚠ CORRECTED — the perf trade-off is worse than originally stated.`**
     `NodeAtOffset.find` has **no span-based pruning**: `find` (line 29-35)
     iterates every declaration, and `findInDecl`/`findInStmt`/`findInExpr`
     recurse the *entire* subtree, testing offset containment only at leaf
     identifiers (e.g. lines 152, 161, 255). So per-token cost is O(total AST
     nodes), not O(declarations) — calling it once per identifier token is
     O(tokens × AST nodes). Before committing, time `computeSemanticTokens`
     on the largest available fixture (largest `.wgsl` by line count in
     `tests/testdata/`, or `tests/testdata/tint/` if symlinked) before/after
     and put the number in the commit body. If it regresses, add a
     "last matching declaration" hint checked before the full scan —
     feasible because `Ast.FunctionDecl` exposes `body.span` and
     `Ast.StructDecl` exposes `decl_span` (`src/Ast.zig:658`), so a
     containment pre-check is cheap. Budget for this rather than treating it
     as contingent.
3. Full gate. Commit: `fix(lsp): semantic tokens resolve identifiers via NodeAtOffset, not whole-module name match`

---

## Block 4 — Completion: member access resolves via NodeAtOffset (Gap 4a)

**`⚠ CORRECTED — the original design for this block was unsound. Do not
implement it as first written.`**

**Probe evidence.** A probe run against the live `Handler` (open document →
`analyzeDocument` → `NodeAtOffset.find`) gave:

| fixture | parse outcome | `find(offset_of_p)` |
|---|---|---|
| `struct S{a:f32} fn f(){ var p: S;` ⏎ `  p.` ⏎ `}` | `p.` statement **dropped** by error recovery (`stmts=1`) | **`.none`** |
| `... let q = p.;` | statement retained (`stmts=2`) | `.ident p`, ref valid |
| `... let q = p.a;` (control) | clean parse | `.ident p`, ref valid |

The first row is *the* dot-completion state: an editor fires
`textDocument/completion` the instant `.` is typed, when nothing follows it.
Error recovery discards that statement, so the base identifier is not in the
AST at that offset. **Replacing the name scan with `NodeAtOffset.find`
outright would make member completion return an empty list in the primary
trigger case** — strictly worse than today's behavior. And nothing would
catch it: `tests/completion_test.zig` has **zero** tests for the `.` path
(16 tests, all general/attribute completion).

1. **Red.** Two tests in `tests/completion_test.zig`:
   - **(a) Regression guard, write this first.** `struct S { a: f32 }` +
     `fn f() { var p: S;` ⏎ `  p.` ⏎ `}`, cursor right after the dot. Assert
     the field `a` is offered. This **passes today** — it exists to fail
     loudly if the naive replacement is attempted. Land it even if Block 4
     is deferred.
   - **(b) The actual shadowing red.** Two functions each with a local `p`
     of a *different* struct type, in a shape where the base ident survives
     parsing (use the `let q = p.;` form, which the probe confirms parses) —
     dot-completion in the second function must offer the second struct's
     fields. Confirm today's whole-module-first-match returns the wrong set.
2. **Green.** In `memberCompletion`, **layer** rather than replace:
   `NodeAtOffset.find(module, start)` first; on `.ident` with a valid `ref`,
   use `analysis.symbol_types.get(ref.index())`. On `.none`, a non-`.ident`
   variant, or an invalid `ref`, **fall back to the existing
   `for (module.symbols.items, 0..)` name scan** (lines 81-86, kept
   verbatim). This fixes shadowing wherever the AST is intact and preserves
   today's behavior wherever error recovery dropped the statement. Document
   the fallback's reason in a comment — it is load-bearing, not vestigial.
   Import `node_at_offset.zig` in `completion.zig`.
3. Full gate. Commit: `fix(lsp): member completion prefers NodeAtOffset for base type, falling back to name match on incomplete parses`

---

## Block 5 — Completion: scope-aware general completion (Gap 4b)

**Context recap:** `generalCompletion` (`completion.zig:113-151`) lists every
symbol in the whole module. Correct scoping requires: (a) module-level decls,
always visible; (b) if the cursor is inside a function, that function's
parameters plus any `let`/`var` declared in an enclosing block that textually
precedes the cursor. This is the highest-effort block; budget it its own
session.

**Mechanism verified.** The probe confirms the span approach survives the
mid-typing parse states this feature actually runs in:
`fn a() { let x = 1.0; }` ⏎ `fn b() {` ⏎ `  le` ⏎ `}` yields
`fn a body.span=7..23`, `fn b body.span=31..39` — `b`'s body span is intact
and contains the cursor even though the partial `le` statement was dropped
(`stmts=0`). Preceding sibling declarations also survive (the Block 4 probe
retained `var p: S;` next to a dropped statement).

1. **Red.** `fn a() { let x = 1.0; } fn b() { /* cursor */ }` — general
   completion inside `b`'s empty body must **not** offer `x`. Second case:
   `fn c() { let y = 1.0; if (true) { /* cursor */ } }` — completion inside
   the `if` body **must** offer `y`. Confirm the first fails today and the
   second already passes (and stays green).
2. **Green.**
   - Add a helper (private fn in `completion.zig`, or a small addition to
     `node_at_offset.zig` — pick at implementation time) that, given `module`
     and `offset`, finds the enclosing `.function` declaration whose
     `decl.function.body.span` contains `offset`; returns null at top level.
   - Within that function, walk the `CompoundStmt` tree from `f.body`,
     descending at each level into the single nested compound whose `.span`
     contains `offset` (an `.if`/`.for`/`.while`/`.loop`/`.switch` body, and
     `loop`'s `continuing` block and each `switch` case body, are each their
     own `CompoundStmt`), otherwise stopping. At each level visited (outer to
     inner, inclusive), collect symbols from `Stmt.decl` entries (`let`/`var`)
     whose own `loc` is `<= offset`.
     - `⚠ CORRECTED — citation.` The original pointed at
       `node_at_offset.zig:129-137` for the `Ast.Decl` pattern; that is
       `findInDecl`'s **module-level** `.let` arm. Statement-level decls
       arrive via `findInStmt`'s `.decl => |d| findInDecl(module, d.decl,
       offset)` at **lines 240-243**. Same `Ast.Decl` union either way, so
       the reuse is valid — just read the right layer.
     - `⚠ CORRECTED — for-init is a known gap, not a maybe.`
       `Ast.ForStmt.init_stmt` is a bare `Stmt`, **not** wrapped in a
       `CompoundStmt` (`node_at_offset.zig:214-217` handles it as a
       standalone statement). A `for (var i = 0; ...)` init decl will
       therefore *not* be picked up by the nested-compound walk. Handle it
       explicitly when descending into a `.for` body. Plan for this; don't
       wait for a fixture to surface it.
   - Always include the function's own parameters (`f.parameters.items`)
     regardless of offset — a parameter is visible for the entire body.
   - Feed the resulting symbol set into `generalCompletion` alongside (not
     instead of) the module-level symbols loop (lines 120-131). The cleanest
     split: change the loop at line 120 to skip `.parameter`/`.let`/`.@"var"`
     kinds unless they're in the locally-computed visible set; module-level
     `.function`/`.@"struct"`/`.@"const"`/`.override` symbols pass through
     unconditionally, matching current behavior.
3. Full gate — this block touches a recursive walk, so add extra fixtures for
   `for`-loop init-scope, `switch`-case-body nesting, and `loop`'s
   `continuing` block, the three least common nested-compound shapes.
4. Commit: `fix(lsp): general completion is scope-aware for locals (no cross-function/pre-declaration leakage)`

**Behavior change:** completion inside a function body offers *fewer* items
(locals from other functions and not-yet-declared same-function locals
disappear) — a correctness fix, but user-visible.

---

## Block 6 — Code action: struct insert-point via AST (Gap 5, minor)

**Context recap:** `findStructBodyInsertPoint` (`code_actions.zig:448+`)
scans `source` text for `struct <name> {`.

1. **Red.** `⚠ CORRECTED — both originally proposed fixtures fail to
   reproduce.` The existing scan enforces a word boundary before/after the
   `struct` keyword (lines 455-458) and matches the name with exact
   `std.mem.eql` (line 470), so neither a `// see MyStruct` comment (no
   `struct` keyword precedes it) nor a name that is a prefix of another
   struct's name (exact match rejects it) breaks anything.

   What **does** break it: the literal token sequence `struct <Name>` inside
   a comment, positioned before a *different* struct's declaration. The scan
   matches the commented occurrence, then walks forward for the next `{`
   (line 475) — which belongs to the wrong struct:
   ```wgsl
   // struct Foo helper
   struct Bar { x: f32 }
   struct Foo { y: f32 }
   ```
   Looking up `Foo` yields an insert point inside `Bar`'s body. Build the red
   around this (wired into an E0600 vertex-return-type quick fix so
   `findVertexReturnTarget` actually reaches the struct branch).
2. **Green.** Look up the target struct in `module.declarations` (match
   `.@"struct"` where the symbol's `original_name` equals `type_name`) and
   compute the insert point from `StructDecl.decl_span`.
   - `⚠ CORRECTED — "members' last field span" does not exist.`
     `Ast.StructMember` (`src/Ast.zig:663-667`) has **only**
     `{ attributes, name, typ }` — no span, no loc. The only span available
     is `StructDecl.decl_span` (`src/Ast.zig:654-661`, "from the `struct`
     keyword through the closing `}`"), so derive the insert point from
     `decl_span.end` (one byte before it is the `}`, since the span ends at
     `prevTokenEnd()`). A member's *name* offset is reachable via
     `module.symbols.items[m.name.index()].loc` if needed, but there is no
     member end offset.
   - `⚠ CORRECTED — there is no module in scope today.`
     `findVertexReturnTarget(handler, diag_range)` (line 384) iterates
     `handler.documents.iterator()` and works purely off
     `entry.value_ptr.source`; it never resolves a URI to an
     `AnalysisResult`. Add `handler.analyzeDocument(entry.key_ptr.*)` inside
     the loop (handling the error/`module == null` cases by falling back to
     the existing text scan), and thread the module into
     `findStructBodyInsertPoint`. This is real added scope the original draft
     didn't budget for.
   - Note the surrounding `->` scan (lines 388-414) stays text-based, so this
     block removes roughly half the text-scanning in this path, not all of it.
3. Full gate. Commit: `fix(lsp): struct insert-point quick fix looks up the AST declaration, not source text`

---

## Block 7 — Docs: update the LSP module map (Gap 6)

1. In `CLAUDE.md`'s Module Map table (after line 128), add one row each for
   `lsp/wire/`, `lsp/native/`, `lsp/wasm/` (the subdirectory),
   `lsp/lspkit/`, `lsp/NativeServer.zig`, `lsp/Debouncer.zig`, and
   — `⚠ CORRECTED, also missing` — `lsp/uri.zig`, `lsp/lspkit_root.zig`,
   `lsp/wire_root.zig`. Derive each purpose by skimming that file's or
   directory's doc comments rather than guessing from the name.
2. No code changes, no gate beyond a sanity read-through.
3. Commit: `docs: add lsp/wire, lsp/native, lsp/wasm, lsp/lspkit, NativeServer, Debouncer to the module map`

---

## Behavior changes (explicit — per repo feedback convention)

| Change | Kind | Runtime effect |
|---|---|---|
| Block 1: `@wgslender/recommended` (or configured packs) now run over LSP by default | New diagnostics surfaced in editors | Users see new warnings they didn't before; opt-out via new `lint.enabled: false` LSP setting |
| Block 1 (2c): W0001/W0002/W0003 move from always-on hand-coded passes to lint-pack-governed rules `⚠ NEW` | Diagnostic provenance change | Same codes/ranges/messages when `recommended` is active; **absent** if the user configures packs that exclude those rules or sets `lint.enabled: false` |
| Block 1: new `lsp_lint_enabled` / `lint.enabled` LSP setting | New config surface (`src/options.zig` + `src/Config.zig` + VS Code `package.json`) | Additive; default `true` preserves Block 1's new behavior unless explicitly disabled |
| Block 4: member completion prefers AST resolution, falls back to name match `⚠ REVISED` | More accurate fields under shadowing; **no** loss on incomplete parses | Fallback retained deliberately — see Block 4's probe table |
| Block 5: general completion no longer lists other functions' locals or not-yet-declared same-function locals | Fewer completion items in some contexts | Correctness fix; no wire-format change, only item-count/content |

**Explicitly not done** (candidate follow-ups, each its own decision):
extending `NodeAtOffset` to support whitespace/comma cursor positions so
signature help can use it too (Block 2 keeps the byte-scan); per-overload
signature disambiguation in signature help using `Overload.resolve` against
already-typed argument expressions; span-based pruning inside
`NodeAtOffset.find` itself (Block 3 measures the cost and mitigates locally
if needed, rather than restructuring the shared walker); replacing the `->`
text scan in `findVertexReturnTarget` (Block 6 replaces only the struct
lookup).

## Definition of done

- [ ] Environment prep done: `external/lsp-kit` populated so
      `zig build lsp` / `lsp-wasm` / `test` actually run.
- [ ] All seven blocks committed, each atomic and conventional.
- [ ] `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
      zig build test` green after every block.
- [ ] `@wgslender/recommended` diagnostics visible over LSP by default
      (Block 1), with a working `lint.enabled: false` opt-out, **and exactly
      one W0001 for a single unused local** (no duplication).
- [ ] Signature help shows real builtin spec signatures and real
      struct/array/pointer/atomic parameter types (Block 2).
- [ ] Semantic tokens, member completion, and general completion resolve
      through scope-correct AST data (Blocks 3-5), with member completion's
      incomplete-parse fallback covered by a regression test.
- [ ] `CLAUDE.md`'s LSP module map lists every file and subdirectory under
      `lsp/` (Block 7).
- [ ] No CI files added; every test entry point remains a local, on-demand
      command.
