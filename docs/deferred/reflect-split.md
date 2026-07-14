# Reflect.zig split — implementation plan

**Status:** deferred work, not started. Planned 2026-07-14, verified against `main` @ `87b967c`.
**Origin:** the master-craft program's "Deferred" register: *"Reflect.zig split (3,571 LOC with an
embedded interpreter): fold into the ConstEval decision."*
**Ordering:** **depends on `consteval-extraction.md` Blocks C0-C1** — that plan extracts the
embedded interpreter (~380 LOC) and is written to land first; this plan splits what remains.
Independent of the uniformity and validator-decomposition tracks. See `docs/deferred/README.md`
for shared house rules.

---

## 0. House rules for whoever implements this

- One block per commit; conventional commits; `⚠ BEHAVIOR` notes for anything wire-visible.
- This is a **pure-move plan**: every block's definition of done is byte-identical behavior. The
  reds are characterization pins that already exist (the reflect suites are the strongest
  fixture set in the repo — ~135 tests plus npm wire pins); no new failing tests are needed.
- Full gate per block: `zig build && zig build wasm && zig build lsp && zig build lsp-wasm &&
  zig build test` (test step `-j1`), **plus** `cd npm/wgslender && npm test` (the reflect JSON
  is wire-pinned there) whenever a block touches serialization.
- The WASM/C-ABI reflect wire shape must not change; if it ever did, the npm wasm artifacts must
  be rebuilt in the same commit (standing project rule). Nothing in this plan changes it.
- No CI. All gates local.

## 1. Current anatomy (verified at `87b967c`)

`src/Reflect.zig` is 3,571 lines. Section map with line ranges:

| Section | Lines | ~LOC | Notes |
|---|---|---|---|
| Module doc + imports | 1-22 | 22 | imports: std, StableId, Ast, Printer |
| `JsonVersion`, `ReflectResult` + toJson* methods | 28-160 | 132 | result container + JSON assembler |
| v2 subset filters + pretty-printer | 162-272 | 111 | `isUniformBinding`…, `prettyPrintJson` |
| Public data types (`BindingInfo`, `TypeInfo`, `EntryPointInfo`, …) | 274-566 | 293 | the wire vocabulary |
| `TypeLayout` internal | 572-576 | 5 | |
| **Driver**: `reflect` / `reflectWithRenamer` | 583-769 | 187 | 3 decl passes + call graph + reachability + stable ids |
| Binding/entry-point extraction (free fns) | 775-1105 | 331 | `extractBinding`, `extractEntryPoint`, IO collection, `parseWorkgroupSize` |
| `primitive_layouts` table | 1111-1158 | 48 | scalar/vec/mat sizes+aligns |
| `ConstValue` | 1170-1190 | 21 | → leaves in ConstEval C1 |
| `LayoutComputer` | 1192-2333 | 1,142 | fields+init :1192-1214; type layout :1216-1368; TypeInfo build :1370-1619; member-attr scan :1621-1717; **interpreter :1719-2008** (→ ConstEval C1); struct layout :2010-2155; array info :2157-2211; name helpers :2213-2231; type-to-string :2233-2332 |
| Layout math (`computeVecLayout`, `computeMatLayout`, `roundUp`, `isPow2`) | 2340-2368 | 29 | `roundUp` is `pub` with **zero external callers** |
| Expr text rendering (override defaults) | 2370-2433 | 64 | `renderExprText` |
| Shorthand parsers + misc | 2435-2536 | 102 | `parseVecShorthand`, `parseMatShorthand`, `sizeOfTypeInfo` |
| Interpreter literal/builtin support | 2538-2608 | 71 | → ConstEval C1 |
| Call graph + resource attribution | 2610-2897 | 288 | `buildCallGraph`, walkers, `propagateEntryReachability`; touches **no** layout/interpreter code |
| JSON serialization (`write*Json` free fns) | 2899-3378 | 480 | reads only the plain public structs; calls **nothing** in LayoutComputer |
| In-file tests | 3380-3571 | 192 | 22 unit tests on helpers/layout math |

**The three verified seams** (each side of the line touches the other only through the named
interface):

1. **Interpreter ↔ everything**: single entry `LayoutComputer.evaluateConstExpr(expr) i32`
   (`-1` = unknown); all 9 callers (`:665, 985, 1049, 1356, 1585, 1639, 2087, 2167, 2264`) use the
   wrapper, none touch `evalConst`/`ConstValue`. → handled by ConstEval C1.
2. **JSON ↔ everything**: `toJsonVersion` (`:73`) and the `write*Json` family read only the
   already-materialized public data structs. They never call LayoutComputer, the interpreter, or
   layout math. Cleanest seam in the file.
3. **Call graph ↔ everything**: operates on `Ast.Module`, writes
   `ReflectResult.functions` + `bindings[].relations`. Independent of layout and interpreter.

**Consumers / API-stability constraints:**
- `src/root.zig:31` re-exports the whole module (`pub const Reflect = @import("Reflect.zig")`),
  and `root.zig:291-314` wraps parse+reflect as the library API. External code spells
  `wgslender.Reflect.JsonVersion`, `wgslender.Reflect.ReflectResult`, `Reflect.reflect`,
  `Reflect.reflectWithRenamer` — **`Reflect.zig` must remain the façade**; every split file is an
  implementation detail re-exported from it.
- Callers: `cli/main.zig:809-853` (reflect subcommand, `--reflect-format v1|v2`, `--compact`);
  `src/Minifier.zig:132-136` (sole `reflectWithRenamer` caller); `src/api_json.zig:142-181, 266-272`
  → `src/wasm.zig:120-163` / `src/lib.zig:587-594` (wire); `lsp/handler/commands.zig:152-164` +
  the four `workspace_commands.zig` variants (custom `wgslender/reflect` LSP request).
- Wire pins: `npm/wgslender/lib/main.d.ts:110-391` (TS mirror of `ReflectResult`/`TypeInfo` etc.),
  `npm/wgslender/test/_suite.cjs:184-274` (layout numbers, subset views, version===2),
  `npm/wgslender/test-cli.js:439-490`; VS Code consumer at `npm/wgslender-vscode/src/reflection/`.

**Duplication finding (drives Block R4):** `Types.Struct.computeLayout` (`src/Types.zig:452-490`)
is a **second, independent implementation** of exactly the algorithm in
`Reflect.computeStructLayout` (`Reflect.zig:2041-2155`) — same roundUp discipline, same
`align_override`/`size_override` handling; the comment at `Types.zig:461` even says "mirroring the
reflect layout path." The vec3-alignment and matrix rules are likewise duplicated
(`Types.zig:308-378` vs `primitive_layouts` + `computeVec/MatLayout`). They serve different type
domains (Types.zig operates on resolved `Types.Type` for the validator; Reflect operates directly
on the AST so reflection works without validation), so **full unification is out of scope** — but
the shared *numeric rules* can live in one place.

Also: Reflect deliberately does **not** implement uniform-vs-storage enforcement (stride ≥16 etc.)
— that lives in `validator/Declarations.zig:1125-1157`. Do not "fix" this during the split; it is
a validator concern by design (`extractBinding` attaches identical layout for both address
spaces, `Reflect.zig:837/847`).

## 2. Design

Target layout (Reflect.zig stays the façade; new files under `src/reflect/`):

```
src/Reflect.zig            ~1,250  doc, JsonVersion, ReflectResult (+toJson* thin methods),
                                   all public data types, driver (reflect/reflectWithRenamer),
                                   binding/entry extraction, renderExprText, in-file tests
                                   + pub re-exports of everything below
src/reflect/Layout.zig       ~980  LayoutComputer (minus interpreter), primitive_layouts,
                                   layout math, shorthand parsers, TypeInfo builders,
                                   type-to-string
src/reflect/Json.zig         ~640  write*Json family, subset filters, prettyPrintJson
src/reflect/CallGraph.zig    ~290  buildCallGraph, walkers, propagateEntryReachability
(src/ConstEval.zig)          ~420  already extracted by consteval-extraction.md C1
```

Rationale:
- **Façade over relocation**: root.zig re-exports the module wholesale and tests/LSP/CLI spell
  `Reflect.X` — keeping every `pub` name reachable from `Reflect.zig` means zero churn outside
  the file. Same pattern as `Validator.zig` re-exporting `validator/*` (Validator.zig:514-610).
- **Json.zig and CallGraph.zig are pure wins** — verified zero coupling to LayoutComputer.
- **Layout.zig keeps LayoutComputer intact** as one struct (its parts — type layout, struct
  layout, TypeInfo build, member attrs, type-to-string — genuinely share the
  `struct_cache`/`renamer`/`fmt_buf` state and call each other; splitting *it* would manufacture
  interfaces, not reveal them).
- The public **data types stay in Reflect.zig**, not Json.zig — they are the module's vocabulary
  (Layout builds them, Json reads them, consumers name them).

### Rejected alternatives

- **Unifying Reflect layout with Types.zig layout**: different input domains (AST vs resolved
  `Types.Type`); unification would force reflection through type resolution, i.e. through half the
  validator, breaking "reflect works on any parse." R4 shares the constants instead.
- **Moving `ReflectResult` into its own file**: churns every consumer's mental model for zero
  coupling gain; the façade already isolates it.
- **A `reflect/` sub-README or doc split**: CLAUDE.md's module map is the documentation surface;
  update it instead.

## 3. Blocks

### Block R1 — carve out `src/reflect/Json.zig`
**Steps:**
1. Move sections D (`:162-272`) and R (`:2899-3378`) — subset filters, pretty-printer, `appendStr`
   / `appendInt` / `appendJsonStr` / `writeSpanField` and the eleven `write*Json` functions — into
   `src/reflect/Json.zig` importing `Reflect.zig` for the data types (one-way import: Json → Reflect).
2. `ReflectResult.toJson*` methods stay as thin delegators calling into Json.zig (public API
   unchanged); `pub const Json = @import("reflect/Json.zig");` on Reflect for discoverability.
3. Watch the import direction: Json.zig importing Reflect.zig while Reflect.zig imports Json.zig
   is a cycle Zig tolerates for namespacing but keep it one-way if possible — alternative: the
   toJson* method bodies move and Reflect.zig calls `Json.writeResult(self, ...)`; data types are
   `pub` in Reflect so Json can reference them via `@import("../Reflect.zig")`. Zig handles this
   mutual import fine (same pattern as Validator ↔ validator/*), so don't contort.
**Gates:** reflect suites; **npm test** (wire bytes); determinism test; full `-j1`.
**LOC:** net ≈ 0 (move). **Risk:** low.

### Block R2 — interpreter extraction = ConstEval plan C0-C1
Execute `docs/deferred/consteval-extraction.md` Blocks C0 and C1 if not already landed. Nothing
else in this plan proceeds past R1 until Reflect's interpreter is behind `ConstEval.eval` and
`evaluateConstExpr` is a façade. (If ConstEval was already done — verify via
`ls src/ConstEval.zig` — skip.)

### Block R3 — carve out `src/reflect/CallGraph.zig`
**Steps:**
1. Move `:2610-2897` (`sampler_pair_builtins`, `buildCallGraph`, `walkBody/Stmt/DeclStmt/Expr`,
   `recordIdent`/`recordCallee`, `maybeRecordTextureSamplerPair`, helpers,
   `propagateEntryReachability`) into `src/reflect/CallGraph.zig`.
2. Driver call sites (`Reflect.zig:733/736`) update to `CallGraph.buildCallGraph(...)` /
   `CallGraph.propagateEntryReachability(...)`; re-export from Reflect if any test names them.
**Gates:** reflect_test call-graph/relations/in_use pins (`tests/reflect_test.zig:2167-2355`),
wgslreflect relations pins (`:144-217`), full `-j1`.
**LOC:** net ≈ 0. **Risk:** low.

### Block R4 — carve out `src/reflect/Layout.zig` + share the numeric rules
**Steps:**
1. Move `LayoutComputer` (now interpreter-free, ≈760 LOC), `TypeLayout`, `primitive_layouts`,
   `computeVecLayout`/`computeMatLayout`/`roundUp`/`isPow2`, and the shorthand parsers
   (`:2435-2536`) into `src/reflect/Layout.zig`. The driver and extraction free-fns keep calling
   through a `pub const LayoutComputer = @import("reflect/Layout.zig").LayoutComputer;` re-export.
2. De-`pub` `roundUp` at module boundary or keep it internal to Layout.zig — it has zero external
   callers (grep-verified); its in-file tests move with it.
3. Cross-reference the duplication: doc comments on `Layout.zig`'s struct-layout section and on
   `Types.Struct.computeLayout` (`src/Types.zig:452`, extending the existing "mirroring" comment
   at :461) naming each other and stating why two engines exist (AST-domain vs resolved-type
   domain). **Optional, judgment call:** lift the shared *constants* (vec3 over-align rule,
   matrix column math) into small pure functions both import — only if it falls out cleanly;
   do not thread new imports into Types.zig if it fights.
4. Move the in-file tests that pin layout math (`:3384-3571` subset) alongside their subjects.
**Gates:** the full reflect suites (all layout-number pins: `:309-1416`, torture at `:1932`,
attribute pins `:1882-2021`), oom test (allocation points must not move), npm test, full `-j1`.
**LOC:** net ≈ 0 moves; Reflect.zig lands at ≈1,250. **Risk:** low-medium (biggest move; the
suites are dense here).

### Block R5 — docs + tier annotations (one small commit)
1. CLAUDE.md module map: replace the single Reflect row with Reflect + reflect/Layout +
   reflect/Json + reflect/CallGraph rows (+ ConstEval row if C1 landed here).
2. root.zig stability-tier doc comments for the reflect exports (house pattern from the
   master-craft program's Block 0.4.6).

## 4. Behavior-change register

| Block | Change | Class |
|---|---|---|
| R1-R4 | none — byte-identical output, wire untouched | — |
| R4 | `roundUp` no longer `pub` from Reflect (zero external callers, grep-verified) | source-level, dead API |

## 5. Success criteria

1. `src/Reflect.zig` ≈1,250 LOC façade; the three seams are files; no file under `src/reflect/`
   imports another sideways except through Reflect's types.
2. Byte-identical: reflect suites (135 tests), npm suite (4 wrapper variants + test-cli),
   determinism, fuzz, OOM — all green with zero fixture edits (except tests that move homes).
3. Zero corpus-golden drift (Reflect isn't in the validation path, so any drift = something
   deeply wrong).
4. CLAUDE.md map updated; `wgslender.Reflect.*` spelling unchanged everywhere.
