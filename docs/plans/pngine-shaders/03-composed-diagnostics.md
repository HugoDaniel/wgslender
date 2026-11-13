# pngine Composed Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate and lint each file in every assembled shader-module context that contains it, publishing only correctly attributed author-local diagnostics.

**Architecture:** A per-root analysis cache owns assembled text, `Validator.AnalysisResult`, lint state, and optional minify estimates. A diagnostic projector maps entries to origins, merges multi-root results, and feeds existing push/pull transports. The legacy single-document path remains intact for non-project files and no-import roots.

**Tech Stack:** Zig 0.16, wgslender Validator/Linter/DCE, phase-02 assembly/map, native and WASM LSP transports.

**Spec:** `docs/plans/pngine-shaders/README.md`

## Global Constraints

- Analyze author text only.
- Every containing valid shader-module root participates.
- No standalone semantic fallback for a known fragment with broken/incomplete context.
- Only open documents are published.
- Push and pull return identical diagnostic sets.
- Existing no-project/no-import diagnostics remain unchanged.
- No closed-file workspace diagnostics requirement.
- No private exhaustive tests.

## Interfaces consumed

- Phase-01 memberships, root IDs, source generations, and invalidation.
- Phase-02 cached `Assembled` and origin mapping.
- `Validator.analyze`, `Linter.run`, `MinifyEstimator`, existing config merge helpers.
- Existing `validateDocumentFull`/`Cheap`, `producePullReport`, and publish adapters (`lsp/handler/diagnostics.zig:40-199`).

## Interfaces produced

```zig
pub const RootAnalysis = struct {
    root: RootId,
    assembled: *const Pngine.Assembled,
    result: *Validator.AnalysisResult,
    input_generation: u64,
};

pub fn analyzeRoot(self: *Handler, root: RootId) !*RootAnalysis;

pub fn validatePngineDocument(
    self: *Handler,
    uri: []const u8,
    options: ValidateOptions,
) ![]LspDiagnostic;

pub fn affectedOpenDocuments(
    self: *const Handler,
    changed_uri: []const u8,
) ![]const []const u8;
```

`Handler.LspRelatedInfo` gains `uri: []const u8`; all existing constructors default it to the current document. Pull result IDs become strings containing document parse version, config generation, and relevant project content/discovery generations.

## File structure

- Create `lsp/handler/pngine_analysis.zig`: root analysis cache.
- Create `lsp/handler/pngine_diagnostics.zig`: projection, merge, project errors.
- Modify `lsp/Handler.zig`, `lsp/handler/diagnostics.zig`.
- Modify `src/Diagnostic.zig` only if shared JSON origin fields are needed by phase 05; no LSP-specific field belongs in core diagnostics.
- Modify native/WASM diagnostic codecs, document sync, lifecycle capabilities.
- Create `tests/pngine_diagnostics_test.zig`, `tests/pngine_lint_test.zig`, `tests/pngine_diagnostic_transport_test.zig`, `tests/pngine_perf_test.zig`.

## Ordered work

### Task 1: Root analysis and invalidation

**Files:** `lsp/handler/pngine_analysis.zig`, `lsp/Handler.zig`, `tests/pngine_analysis_test.zig`.

- [ ] Add red tests proving sibling types/functions resolve, unsaved edits are analyzed, and root caches invalidate selectively.
- [ ] Run `Validator.analyze` on assembled text, attach DCE/liveness as the existing analysis path does (`lsp/Handler.zig:548-556`), and retain the assembly for the result lifetime.
- [ ] Cache by root and content key; reject stale pointers before releasing a previous analysis.
- [ ] Keep `analyzeDocument` unchanged for standalone callers during this phase.
- [ ] Add per-root minify-estimate slots so full diagnostics do not re-estimate every root on every request.
- [ ] Run analysis, OOM, and incremental cache suites; all pass.
- [ ] Commit: `feat: analyze assembled pngine roots`.

### Task 2: Diagnostic projection and related locations

**Files:** `lsp/handler/pngine_diagnostics.zig`, `lsp/Handler.zig`, both diagnostic codecs, `tests/pngine_diagnostics_test.zig`, existing diagnostic parity tests.

- [ ] Add red tests for file/inline origins, hoisted directives, part boundaries, related information on another file, and EOF.
- [ ] Convert assembled ranges with `Assembled.toOrigin`; discard only entries with no safe author representation and emit one `P0001` explaining the degraded projection.
- [ ] Extend related-information encoders to use each item’s URI rather than always using the current URI (`lsp/lspkit/diagnostics.zig:58-72`, `lsp/wire/diagnostics.zig:72-90`).
- [ ] Keep primary diagnostics in the requested document’s report; related entries may point to SJON or another WGSL part.
- [ ] Preserve quick-fix payloads only when their primary and fix ranges map to that document.
- [ ] Run native/WASM byte-parity tests; all pass.
- [ ] Commit: `feat: project composed diagnostics to author files`.

### Task 3: Multi-root validation and graph/hole errors

**Files:** `lsp/handler/pngine_diagnostics.zig`, tests.

- [ ] Add red cases for identical errors in four roots, root-specific unresolved names, cycles, unknown imports, missing files, and `:requires`.
- [ ] Union validator errors; deduplicate identical origin/code/message findings and attach all failing root forms.
- [ ] Rewrite E0100 with the specified “declared nowhere” suffix and root-related information.
- [ ] Emit `P0002` for assembly failure and `P0003` for a listed hole with no module-scope declaration. Use parsed module declarations rather than substring matching.
- [ ] For a known fragment with no valid shader-module root, return local syntax plus `P0001` or `P0004`; do not report standalone unresolved identifiers.
- [ ] Keep unrelated valid programs usable when one program is broken.
- [ ] Run diagnostics tests; all `C*` rows pass.
- [ ] Commit: `feat: merge diagnostics across pngine roots`.

### Task 4: Whole-unit lint semantics

**Files:** `lsp/handler/pngine_diagnostics.zig`, `tests/pngine_lint_test.zig`.

- [ ] Add red fixtures for W0001/W0002/W0003 in all roots, a subset, or none; include style rules and conflicting quick fixes.
- [ ] Run configured packs against each root analysis using existing extends/override construction (`lsp/handler/diagnostics.zig:143-197`).
- [ ] Intersect unused/dead findings across roots by origin and symbol; include root names in the message/related information.
- [ ] Union other lint findings and deduplicate exact repeats.
- [ ] Restrict whole-module size findings to an unambiguous root context.
- [ ] Disable unsafe cross-part/inline/conflicting fixes while retaining local valid fixes.
- [ ] Run existing and new lint suites; no rule registration or default severity changes occur.
- [ ] Commit: `fix: judge fragment lints on assembled modules`.

### Task 5: Push, pull, refresh, and result IDs

**Files:** `lsp/Handler.zig`, `lsp/handler/diagnostics.zig`, `lsp/NativeServer.zig`, WASM document sync/lifecycle, native lifecycle, transport tests.

- [ ] Add red tests proving an edit to a shared sibling republishes every affected open document and changes pull result IDs.
- [ ] Route composed files through `validatePngineDocument` on cheap/full paths.
- [ ] Republish affected open documents, not only the edited URI; arm each for the existing debounced full pass.
- [ ] Include project generations in pull result IDs without reintroducing numeric wrap/collision ambiguity.
- [ ] Set `diagnosticProvider.interFileDependencies=true` in both capability implementations; leave workspace diagnostics false.
- [ ] Send diagnostic refresh after watched project changes; do not require clients to support refresh for correctness of subsequent pulls.
- [ ] Run push/pull/capability/config-refresh suites on both transports; all pass.
- [ ] Commit: `feat: publish and pull pngine-aware diagnostics`.

### Task 6: Corpus and performance acceptance

**Files:** corpus gate tests and `tests/pngine_perf_test.zig`.

- [ ] Encode the four corpus projects as read-only gate inputs; synthetic copies inside wgslender keep ordinary tests self-contained.
- [ ] Pin the measured clock failures as red before the composed path is enabled: the baseline is the set of W0001s that standalone `wgslender lint` reports on `clock/kernels/scene_lib.wgsl` today, recorded as named fixtures — the derivation is the contract, not a remembered count.
- [ ] Verify no W0001 for any of those fixture names when used by the project, no missing `Transform2D`/`Surface`, and no false not-callable findings for the named scene functions.
- [ ] Verify demo diagnostics cover all four roots and bounce/veclock match legacy output.
- [ ] After warm discovery, run 200 edits: require zero SJON parses, zero discovery scans, zero unrelated-root analyses, and no project disk reads.
- [ ] Commit: `test: gate pngine diagnostics on the inercia corpus`.

## Exhaustive use-case inventory

| ID | Fixture or synthetic input | Action | Expected result | Why phase 03 |
|---|---|---|---|---|
| C01 | `clock/scene_lib.wgsl` | Full lint | No false unused warnings for declarations used by the assembled project. | Original measured defect. |
| C02 | `clock/clock_scene.wgsl` | Validate | `Transform2D` and `Surface` resolve from `sceneLib`. | Sibling type references. |
| C03 | `clock/scenes.wgsl` | Validate | Fragment functions resolve; no false E0204. | Root-to-fragment references. |
| C04 | `clock` fragment using another fragment | Validate | Post-order sibling declarations resolve regardless of textual declaration order. | WGSL module scope. |
| C05 | `demo/palette.wgsl` | Validate/lint all roots | All four roots analyzed; used declarations are not globally dead. | Shared fragment. |
| C06 | Same fragment error present in all four demo roots | Publish | One finding with four root relations, not four identical squiggles. | Multi-root dedupe. |
| C07 | Hole satisfied in root A but not root B | Publish fragment | One E0100 naming B and linking B’s SJON form; no claim that A fails. | Root-specific errors. |
| C08 | Root declares a required name | Validate | `:requires` hole is satisfied even when declaration is textually later. | Root-supplied hole. |
| C09 | Sibling fragment declares required name | Validate | Hole is satisfied. | Sibling-supplied hole. |
| C10 | `:requires [noise]`, no declaration | Validate | `P0003` plus related SJON requirement/root locations. | Explicit missing hole. |
| C11 | Required name used only by dead code | Validate | Still checked before DCE; no exemption. | pngine requirement semantics. |
| C12 | E0100 unresolved identifier | Publish | Message says declared nowhere in the named module; related info points to `.sjon`. | Actionable unresolved diagnostics. |
| C13 | Unknown type from a genuinely absent declaration | Publish | Original E0200 at author range with root context. | Negative type case. |
| C14 | Name exists but is not callable | Publish | Preserve E0204; do not rewrite as “declared nowhere.” | Avoid false message broadening. |
| C15 | Cross-part duplicate declaration | Publish both open parts | Each gets its local primary range and cross-file related location. | Cross-file diagnostics. |
| C16 | Error on hoisted `enable` | Publish | Diagnostic lands on original directive text. | Hoisted mapping. |
| C17 | Error at added part newline | Publish | Zero-length author EOF location on preceding part. | Part boundary. |
| C18 | Unterminated root block at EOF | Publish root | Root EOF, not the last imported fragment. | Root fallback. |
| C19 | Diagnostic range crosses parts | Project | No fake single range; `P0001` degradation if no honest primary location exists. | Unmappable diagnostic. |
| C20 | Missing imported file | Validate root | `P0002`/missing-source context with SJON relation; other roots still report. | Missing file. |
| C21 | Cycle | Validate affected file | `P0002` naming cycle path; no standalone semantic flood. | Cycle negative case. |
| C22 | Unknown fragment | Validate affected root | `P0002` at project context with root/import relation. | Unknown import. |
| C23 | Depth/count/directive overflow | Validate | `P0002` identifies the violated bound. | Bounds. |
| C24 | Broken SJON with no prior graph | Open WGSL | No phantom composed diagnostics; SJON owns its syntax errors. | Initial syntax error. |
| C25 | Broken SJON with last-known-good graph | Edit WGSL | Stale context warning plus current author-text analysis; no claim graph is fresh. | Recovery behavior. |
| C26 | File in no project | Validate | Legacy diagnostics byte-equivalent. | Standalone compatibility. |
| C27 | Orphan `wgsl` fragment with no root | Open | Syntax plus `P0001`; no standalone unknown-hole errors. | Known but unrooted fragment. |
| C28 | Pass-only fragment | Open | Syntax plus `P0004`; no semantic-valid claim. | Generated-prelude boundary. |
| C29 | Fragment in pass and shader-module roots | Open | Shader-module diagnostics plus explicit pass limitation; no duplicate local syntax. | Mixed membership. |
| C30 | Inline-code defect alongside file fragment | Open file/inline part | Correct origin report; no file diagnostic pretending inline text is on disk. | `:code` diagnostics. |
| C31 | Current buffer introduces error before save | Cheap/full validation | Assembled analysis uses the edit immediately. | Current unsaved buffer. |
| C32 | Open sibling introduces error | Republish current file | Current file updates using sibling buffer; disk is ignored. | Sibling unsaved buffer. |
| C33 | Closed sibling changes on disk | Watch/refresh | Dependent open documents update. | External changes. |
| C34 | W0001 true in every root | Lint | One globally unused finding naming all roots. | Intersection positive. |
| C35 | W0001 true in only one root | Lint shared fragment | Suppressed as globally unused. | Fragment-hostile lint fix. |
| C36 | W0002 reachable from one root only | Lint | Suppressed for shared declaration. | Whole-project liveness. |
| C37 | W0003 used by one root only | Lint | Suppressed for shared declaration. | Binding-lint policy. |
| C38 | Ordinary style lint identical in two roots | Lint | One author-local finding. | Non-liveness dedupe. |
| C39 | Two roots suggest different quick fixes | Code-action input | No unsafe fix; diagnostic remains. | Fix ambiguity. |
| C40 | Local lint fix valid in all roots | Code action | Existing fix payload survives at mapped local range. | Safe quick-fix compatibility. |
| C41 | Minify-size rule on unique root | Full diagnostics | Existing behavior and estimate cache apply. | Root-level M-rules. |
| C42 | Shared fragment with different root sizes | Full diagnostics | No single module-size claim attached to the fragment. | Ambiguous module metric. |
| C43 | Edit one clock part | Push | Only open documents sharing `sceneCode` are recomputed/published. | Affected-set policy. |
| C44 | Edit demo palette | Push | All open documents in all four affected roots update. | Shared-root fanout. |
| C45 | Pull immediately after sibling edit | `textDocument/diagnostic` | Same set as full push; previous ID does not return Unchanged. | Pull freshness. |
| C46 | Pull twice with no relevant change | Pull | Second returns Unchanged. | Result-ID caching. |
| C47 | Diagnostics/lint disabled | Push/pull | Existing empty/disabled behavior is preserved. | Config compatibility. |
| C48 | WASM project source missing | Push/pull | Honest incomplete-project result, no empty module validation. | WASM negative case. |
| C49 | `bounce` and `veclock` | Validate/lint | Legacy no-import output unchanged. | No-regression corpus. |
| C50 | 200 warm-cache edits | Performance gate | Zero SJON parses/scans/disk refreshes; only dependent roots analyze. | Keystroke budget. |

## Red-first and gate commands

- `zig build test -j1`: exit `0`; all `C01–C50`, existing diagnostic, pull, publish, and parity suites pass.
- `zig build lsp && zig build lsp-wasm`: both exit `0`.
- `(cd npm/wgslender-lsp && npm test)`: exit `0`.
- Corpus gate: all clock/demo composed roots valid under author-text semantics except explicitly injected negative fixtures; bounce/veclock remain valid.
- Performance test prints counters; green shape is exactly zero SJON/discovery/disk-refresh counts during the warm 200-edit burst.

## Stop-and-report conditions

- Validator diagnostics contain ranges that cannot be mapped with the phase-02 contract.
- Correct lint behavior requires changing core rule semantics rather than merging root results.
- Push and pull cannot share a result set without transport-specific behavior.
- A pass/corpus result needs generated text or pngine lowering.
- The performance counter shows any SJON parse or discovery scan on the WGSL edit path.

## Risks

- **Multi-root diagnostic volume:** exact dedupe and explicit root relations keep it bounded by actual findings.
- **Lint suppression hiding a root-specific issue:** only W0001/W0002/W0003 use intersection; the diagnostic policy documents why.
- **Stale cache pointers:** assembly and analysis share an owner and are replaced atomically.
- **Cross-file related-info compatibility:** additive URI use is covered by native/WASM wire tests.
- **Warm-edit cost:** counter-based tests gate project work independently of noisy wall-clock timings.

---
