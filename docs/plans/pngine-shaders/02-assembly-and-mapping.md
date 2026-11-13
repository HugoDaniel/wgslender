# pngine Assembly and Origin Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce byte-for-byte pngine-compatible author-text modules and a bidirectional map between every assembled range and its author origin.

**Architecture:** A pure assembler consumes phase-01 `Program`/`Store` data. It mirrors pngine’s explicit-stack post-order, directive scanner, blanking, newline termination, and line rows. A segment index adds byte-offset mapping without changing the parity-critical line table.

**Tech Stack:** Zig 0.16, phase-01 project store, wgslender `PositionMapper`/`SourceMap.LineIndex`, pngine test-only oracle.

**Spec:** `docs/plans/pngine-shaders/README.md`

## Global Constraints

- Assembled output is author text only.
- Root imports, then transitive dependencies in post-order, each once, root last.
- Mirror all four pngine bounds exactly.
- Lines, not byte offsets, are the parity contract; byte segments are an additional wgslender index.
- No recursion or unbounded traversal.
- Open-buffer text is already resolved by `Store`.
- No minification or pngine lowering in `Assembled.text`.

## Interfaces consumed

```zig
Store.program(id) ?*const Program
Store.part(id) ?*const Part
Store.textForPart(id: PartId) !SourceText
```

`SourceText` carries `text`, `origin`, `content_hash`, and whether it came from an open buffer, injection, or disk. `textForPart` is part of the phase-01 `Store` interface (produced in 01 Task 5); this phase consumes it as-is.

## Interfaces produced

```zig
pub const ByteRange = struct { start: u32, end: u32 };
pub const OriginRange = struct { origin: OriginKey, range: ByteRange };

pub const Assembled = struct {
    text: []const u8,
    rows: []const LineRow,
    segments: []const Segment,
    root: RootId,

    pub fn deinit(self: *Assembled, gpa: std.mem.Allocator) void;
    pub fn locateLine(self: *const Assembled, line: u32) LocatedLine;
    pub fn toOrigin(self: *const Assembled, range: ByteRange) ?OriginRange;
    pub fn fromOrigin(self: *const Assembled, origin: OriginKey, range: ByteRange) ?ByteRange;
    pub fn offsetToOrigin(self: *const Assembled, offset: u32) ?OriginOffset;
    pub fn offsetFromOrigin(self: *const Assembled, origin: OriginOffset) ?u32;
};
```

`toOrigin` returns null when a single contiguous origin range cannot represent the input. Later phases must split references and reject unmappable quick fixes rather than clamping silently.

## File structure

- Create `src/pngine/Assemble.zig`: graph walk and text output.
- Create `src/pngine/Directives.zig`: leading-directive scanner and equality.
- Create `src/pngine/Mapping.zig`: line rows, byte segments, origin conversion.
- Export them through `src/pngine/Pngine.zig`.
- Create `tests/pngine_assemble_test.zig`, `tests/pngine_mapping_test.zig`.
- Create `pngine/tests/zig/wgslender_assembly_parity.zig` and register a dedicated pngine build step.

## Ordered work

### Task 1: Graph order and refusal behavior

**Files:** `src/pngine/Assemble.zig`, `tests/pngine_assemble_test.zig`.

- [ ] Port the red cases for chain, diamond, shared paths, unknown import, self-cycle, multi-node cycle, and bounds from the inventory.
- [ ] Implement an explicit stack with `on_path` and `done`, following the semantic contract at `pngine/src/dsl_sjon/fragments.zig:789-880`.
- [ ] Produce `ImportCycle`, `UnknownFragment`, `TooDeep`, `MissingSource`, and `OutOfMemory` with root/cycle context.
- [ ] Verify post-order and exactly-once output before adding directive handling.
- [ ] Commit: `feat: assemble pngine fragment graph in dependency order`.

### Task 2: Directive hoist and byte-exact text

**Files:** `src/pngine/Directives.zig`, `src/pngine/Assemble.zig`, assembly tests.

- [ ] Add red golden strings for every directive and boundary case in `A10–A25`.
- [ ] Implement leading-trivia scanning, nested WGSL comments, semicolon search, whitespace-insensitive equality, and `MAX_DIRECTIVES`.
- [ ] Emit unique hoisted directives in walk order; blank every original non-newline byte.
- [ ] Newline-terminate empty and unterminated parts exactly like `appendTerminated` (`pngine/src/dsl_sjon/fragments.zig:393-437`).
- [ ] Preserve root/no-import text and empty line-table fast-path semantics.
- [ ] Run all assembly tests with allocation-failure sweeps over the final text/rows ownership handoff.
- [ ] Commit: `feat: mirror pngine WGSL directive hoisting`.

### Task 3: Bidirectional origin mapping

**Files:** `src/pngine/Mapping.zig`, `tests/pngine_mapping_test.zig`.

- [ ] Write red tests for every line in both directions, hoisted/multiline directives, blanked duplicates, CRLF, UTF-8/UTF-16, empty parts, added newlines, and EOF.
- [ ] Build line rows and ordered byte segments during output construction; do not rescan to guess origins afterward.
- [ ] Map columns unchanged within a part, then use the origin’s own line index for UTF-16 conversion.
- [ ] Map original blanked directives to their hoisted semantic copy when one exists; map diagnostics only from hoisted/body text back to the author.
- [ ] Attribute a synthetic part-ending newline to that part’s EOF and past-end diagnostics to root EOF, matching `locate`’s root fallback (`pngine/src/dsl_sjon/fragments.zig:201-205`).
- [ ] Return null for ranges that cross unrelated origins or have no author representation.
- [ ] Run mapping tests and existing position/source-map suites; all pass.
- [ ] Commit: `feat: map assembled WGSL back to author origins`.

### Task 4: Store integration and cache keys

**Files:** `src/pngine/Store.zig`, `src/pngine/Assemble.zig`, `tests/pngine_store_test.zig`.

- [ ] Add red tests for current-buffer edits, sibling edits, closed-disk edits, multi-root independence, and missing source recovery.
- [ ] Assemble through `Store.textForPart`, never directly from disk inside the pure assembler.
- [ ] Cache `Assembled` by `(RootId, graph generation, ordered part hashes)`; preserve unrelated roots on an edit.
- [ ] Bump `content_generation` when any assembled result changes.
- [ ] Verify repeated assembly without changes performs no reads or allocations beyond cache lookup.
- [ ] Commit: `perf: cache assembled pngine roots by content`.

### Task 5: Cross-repo parity gate

**Files:** pngine test harness/build step, wgslender parity fixture descriptors.

The harness compiles the wgslender side itself: a module rooted in the planned `src/pngine/*` library, reached through pngine's path dependency but constructed like pngine's other test modules, with pngine's own `sjon` module injected as the `sjon` import. It must not consume `wgslender_dep.module("wgslender")` (`pngine/build.zig:33-37`): wgslender pins SJON by URL + hash, so that module would resolve wgslender's dependency graph and fetch a second SJON instance into the test process. Injection is safe because the planned `src/pngine/*` modules are pure library code that never imports `build_options` — the `pngine_support` gate lives in the build graphs, the `src/root.zig` export, the CLI, and the Handler, none of which this parity module compiles (wgslender imports no `build_options` anywhere today).

- [ ] Add a failing comparison for one clock root before wiring the expected values.
- [ ] In pngine’s test process, construct its native `fragments.Table` and wgslender’s phase-01 graph from the same fixture descriptors.
- [ ] Compare assembled bytes and every line-row field: origin kind/name/path, part name, first line, count, source line, and root flag.
- [ ] Cover synthetic order/dedupe/cycle/directive cases plus all clock/demo/bounce/veclock roots.
- [ ] For cycle/unknown/bound cases compare error class and cycle path, not prose.
- [ ] Register `test-wgslender-assembly-parity`; make `-Dinercia=<path>` required for the corpus lane and fail with a clear message if absent.
- [ ] Run the gate; green means zero byte differences and zero row differences.
- [ ] Commit: `test: prove pngine assembly parity across both implementations`.

## Exhaustive use-case inventory

| ID | Fixture or synthetic input | Action | Expected result | Why phase 02 |
|---|---|---|---|---|
| A01 | Root with no imports | Assemble | Root text is unchanged; rows are empty on the fast path. | Existing-project compatibility. |
| A02 | `base <- mid <- root` | Assemble | `base`, `mid`, root order. | Basic dependency order. |
| A03 | Diamond `shared <- left/right <- root` | Assemble | `shared` appears once before either dependant. | Include-once invariant. |
| A04 | Same fragment listed twice through different paths | Assemble/map | One text contribution and one body row. | Path dedupe. |
| A05 | `clock` graph | Assemble `sceneCode` | `sceneLib` once, four fragments in written post-order, root last. | Depth-3 corpus parity. |
| A06 | `demo` graph | Assemble each root | Each contains `palette` once plus its own root text; roots remain independent. | Multi-root corpus parity. |
| A07 | Unknown direct or transitive import | Assemble | `UnknownFragment` naming the unresolved edge; no partial unit returned. | Missing graph node. |
| A08 | Self-cycle | Assemble | `ImportCycle` path `me → me`. | Minimal cycle. |
| A09 | Multi-node cycle | Assemble | Ordered cycle path, no loop/stack overflow. | Cycle reporting. |
| A10 | Depth 64 vs 65 | Assemble | Boundary accepted/refused exactly as pngine. | Depth bound. |
| A11 | 64 vs 65 imports on one form | Extract/assemble | Schema/graph bound and assembler behavior agree. | Import bound. |
| A12 | 1024 vs 1025 reached fragments | Assemble | Exact `MAX_FRAGMENTS` behavior. | Count bound. |
| A13 | 64 vs 65 leading directives | Assemble | Exact directive bound; no dropped 65th directive. | Directive bound. |
| A14 | Root `enable f16;` plus ordinary fragment | Assemble | Directive first; original root line blanked to equal width. | Root hoist. |
| A15 | Fragment `requires …;` and root `diagnostic …;` | Assemble | Both hoisted in part-walk order. | All directive kinds. |
| A16 | Same directive spelled with different whitespace in three parts | Assemble | One hoisted copy; all three originals blanked. | Deduplication. |
| A17 | Directives differing only by a comment | Assemble | Not deduplicated, matching pngine’s documented rule. | Exact equality edge. |
| A18 | Directive after a declaration | Assemble | Left in place for WGSL to diagnose. | Leading-region boundary. |
| A19 | Unterminated directive | Assemble | Left untouched; no guessed semicolon. | Malformed WGSL handling. |
| A20 | Semicolon inside line/nested block comment | Assemble | Comment does not terminate the directive. | Scanner correctness. |
| A21 | Directive and declaration on one line | Assemble/map | Blanking preserves every later column. | Column invariant. |
| A22 | Multiline directive | Assemble/map | Hoist row records original source line and full line count. | Multiline mapping. |
| A23 | Directive-looking text in comments | Assemble | No hoist. | Trivia handling. |
| A24 | Empty fragment | Assemble | One owned output line and one row. | Empty-part boundary. |
| A25 | Missing trailing newline on one part | Assemble | Next part begins on a fresh line; row counts do not drift. | Part-boundary invariant. |
| A26 | CRLF and mixed newline text | Assemble/map | Bytes preserved except mandated appended newline; local lines map correctly. | Newline robustness. |
| A27 | File and `:code` parts mixed | Assemble/map | Correct origin union for every row. | Inline-code composition. |
| A28 | Unsaved current part adds declaration | Assemble | New text appears; disk text does not. | Current-buffer authority. |
| A29 | Unsaved sibling part changes | Assemble containing root | New sibling text appears in every affected root only. | Sibling overlays. |
| A30 | Closed sibling missing/unreadable | Assemble | `MissingSource`; no empty substitution. | Missing-file safety. |
| A31 | Body diagnostic range | Map to origin | Exact author file/inline range. | Diagnostic mapping. |
| A32 | Diagnostic on hoisted directive | Map to origin | Original directive line/column, not assembled line 1. | Hoisted diagnostic rule. |
| A33 | Request on original directive | Map from origin | Hoisted token location when present. | Request-side mapping. |
| A34 | Request on duplicate blanked directive | Map from origin | No semantic target if no hoisted copy exists. | Negative mapping case. |
| A35 | Range crosses two parts | Map as one range | Null; caller must split or refuse. | No false contiguous origin. |
| A36 | Diagnostic on synthetic terminating newline | Map | Zero-length location at that part’s EOF. | Exact boundary rule. |
| A37 | Unterminated block at assembled EOF | Map | Root EOF, matching pngine fallback. | Past-end rule. |
| A38 | Non-ASCII before diagnostic | Map/convert | Byte columns remain correct and UTF-16 conversion uses origin text. | Position encoding. |
| A39 | Fragment shared by four roots | Map each assembly | Same origin/local range in each, independent assembled offsets. | Multi-root mapping. |
| A40 | Pass root with imports | Inspect assembly request | No generated prelude/post variant is produced; later diagnostics can identify unsupported context. | Author-only pass boundary. |
| A41 | pngine math constants/overrides present | Compare text | No substitution or specialization occurs. | No-lowering constraint. |
| A42 | OOM at every output/row/segment allocation | FailingAllocator sweep | No leak/double free and no partially cached unit. | Ownership robustness. |

## Red-first and gate commands

- `zig build test -j1`: exit `0`; all `A01–A42` cases and OOM sweeps pass.
- `zig build wasm && zig build lsp-wasm`: both exit `0`.
- From pngine: `zig build test-wgslender-assembly-parity -Dinercia=../inercia-2026`: exit `0`, with one compared result per corpus root and no byte/row differences.
- Cache test: warm `sceneCode`, edit `clock_scene.wgsl`, and verify only `sceneCode`-dependent entries rebuild; demo root caches remain untouched.

## Stop-and-report conditions

- Any corpus byte/line-row mismatch. Report root, first differing byte, and first differing row; do not update expectations to wgslender’s output.
- A directive case requires a different scanner from pngine. Escalate the semantic mismatch rather than documenting a new rule unilaterally.
- A range cannot be mapped without inventing author bytes. Keep it unmappable and make later phases decline the edit.
- A pass test appears to require generated text. Stop at the author-text boundary.

## Risks

- **Two implementations drifting:** the pngine-hosted gate compares behavior on every relevant synthetic shape and corpus root.
- **Dual mapping confusion:** body, hoisted, blanked, and synthetic segments have distinct types and tests.
- **Cache memory growth:** entries are per root and replaced by content key; program/document removal releases them.
- **OOM ownership:** failure sweeps include all output collections, not only text.

---
