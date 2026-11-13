# pngine Project Discovery and Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover every pngine part referencing a WGSL file and maintain a content-correct, incrementally invalidated project graph on native and WASM.

**Architecture:** A `wgslender.Pngine.Store` owns canonical documents, programs, parts, memberships, and source overlays. Native discovery reads through `std.Io`; WASM receives SJON catalogs and requested WGSL text from the host. Markers guide candidate discovery but references alone establish membership.

**Tech Stack:** Zig 0.16, SJON 1.7.0, existing wgslender build/LSP infrastructure, VS Code `workspace.fs` and file watchers.

**Spec:** `docs/plans/pngine-shaders/README.md`

## Global Constraints

- No dependency on pngine at runtime.
- No typed graph from an SJON tree with error-severity parse diagnostics.
- No marker-only membership.
- Open buffer > injected source > disk.
- Preserve all valid memberships; never choose first.
- `-Dlsp=false` neither fetches SJON nor exposes project entry points.
- New configuration goes through `src/options.zig`.
- No private `tests/exhaustive/` dependency.

## Interfaces consumed

- `sjon.parse(gpa, source)` and `sjon.Parser.parse` (`SJON/src/root.zig:348-354`).
- `Ast.Tree.formHeader`, `kvpairHeader`, `vectorElements`, `stringText`, `symbolText`, and `spanOf` (`SJON/src/Ast.zig:1340-1387`, `:1523-1538`).
- `Handler.openDocument`, `changeDocument`, `changeDocumentIncremental`, and `closeDocument` (`lsp/Handler.zig:275-329`).
- Existing native/WASM document-sync adapters.

## Interfaces produced

```zig
pub const Store = struct {
    pub fn init(gpa: std.mem.Allocator) Store;
    pub fn deinit(self: *Store) void;

    pub fn setWorkspaceRoots(
        self: *Store,
        roots: []const []const u8,
    ) !void;

    pub fn upsertBuffer(
        self: *Store,
        uri: []const u8,
        text: []const u8,
        origin: SourceOrigin,
    ) !void;

    pub fn removeBuffer(self: *Store, uri: []const u8) void;
    pub fn invalidatePath(self: *Store, path: []const u8) void;

    pub fn membershipsFor(
        self: *Store,
        io: ?std.Io,
        wgsl_uri: []const u8,
    ) !MembershipSet;

    pub fn program(self: *const Store, id: ProgramId) ?*const Program;
    pub fn part(self: *const Store, id: PartId) ?*const Part;
    pub fn textForPart(self: *Store, id: PartId) !SourceText;
};
```

`MembershipSet` owns a stable, path-sorted slice of `{program, part, containing_roots}` records. `SourceOrigin` is `open_buffer`, `injected`, or `disk`. `textForPart` resolves a part's current text under that precedence and returns a `SourceText` carrying `text`, `origin`, and `content_hash` — the source query D37/D38 exercise here, so phase 02 consumes the member rather than adding it. `Store` also exposes monotonically increasing `discovery_generation` and `content_generation` counters for later result IDs.

## File structure

- Create `src/pngine/Pngine.zig`: public exports and shared constants.
- Create `src/pngine/Types.zig`: IDs, origins, parts, roots, diagnostics, memberships.
- Create `src/pngine/Store.zig`: source overlays, caches, reverse index.
- Create `src/pngine/Discovery.zig`: workspace/ancestor/bundle discovery.
- Create `src/pngine/Extract.zig`: strict SJON-to-graph extraction.
- Create `src/pngine/Path.zig`: URI/path normalization and identity.
- Modify `src/root.zig`: experimental `Pngine` export when enabled.
- Modify `src/Config.zig`, `src/options.zig`: `lsp.pngine.enabled`, default `true`.
- Modify `build.zig.zon`, `build.zig`: pinned dependency and build option.
- Modify native/WASM lifecycle/document-sync dispatch for roots and watched files.
- Create `npm/wgslender-vscode/src/pngine-sync.ts`; modify both extension entry points and `client-options.ts`.
- Create focused tests named in the tasks.

## Ordered work

### Task 1: Dependency and build boundary

**Files:** `build.zig.zon`, `build.zig`, `src/root.zig`, `tests/pngine_build_test.zig`.

- [ ] Add a compile/fixture test that imports `sjon`, parses a fragment document, and is referenced from a WASM smoke object.
- [ ] Run the new native and WASM smoke steps; expect failure before the dependency exists.
- [ ] Add SJON by URL + hash at the approved 1.7.0 source revision. Record the actual revision/hash in the commit; do not substitute a local path.
- [ ] Resolve it with `plugin-exec=false`; add `pngine_support` to native CLI, Handler, tests, and both WASM graphs.
- [ ] Keep `-Dlsp=false` ahead of SJON resolution and compile project calls out of that CLI/core variant.
- [ ] Verify `zig build test -j1`, `zig build wasm`, `zig build lsp-wasm`, and `zig build -Dlsp=false`; all must exit `0`.
- [ ] Commit: `build: add optional pngine project parser dependency`.

**Stop:** If the pinned SJON revision cannot compile `sjon.parse` for `wasm32-freestanding` without libc, stop and report the import chain; do not add a filesystem shim or enable executable plugins.

### Task 2: Canonical path and source identity

**Files:** `src/pngine/Path.zig`, `lsp/uri.zig`, `tests/pngine_path_test.zig`.

- [ ] Write table tests for POSIX, percent escapes, Windows drive/UNC, `.`/`..`, missing paths, symlinks, non-file URIs, and case rules.
- [ ] Run `zig test` for the new suite through a named build step; expect missing-module failure.
- [ ] Implement `fileUriToPath`, `pathToFileUri`, `normalizeLexical`, and `canonicalExisting`. Extend rather than duplicate the POSIX-only helper documented at `lsp/uri.zig:1-17`.
- [ ] Keep URI spelling for responses separate from canonical filesystem identity.
- [ ] Run the path suite and existing `lsp/uri.zig` tests; all pass with no allocation leaks.
- [ ] Commit: `feat: canonicalize pngine project paths`.

### Task 3: Strict graph extraction

**Files:** `src/pngine/Types.zig`, `src/pngine/Extract.zig`, `tests/pngine_extract_test.zig`.

- [ ] Add red fixtures for `wgsl`, `shader-module`, `pass`, `:code`, `:file`, imports, requires, malformed forms, duplicates, and unsupported SJON imports.
- [ ] dupeZ every SJON input before `sjon.parse`: the signature takes `[:0]const u8` and asserts `Binary.MAX_FILE_SIZE` (`SJON/src/root.zig:350-354`), and SJON's own reader dupeZ's first (`SJON/src/lsp/editor_config.zig:152-154`); an over-size document is a per-document failure, never an assert.
- [ ] Implement a non-recursive form walk using SJON’s public AST readers. Record form/name/file/code/import spans.
- [ ] Reject both/neither `:code` and `:file`, missing names, and non-symbol imports as graph errors; never invent a path or empty fragment. A pass's `:file` is a data-file-list — WASM data segments, not WGSL source (`pngine/schema/pngine.sjon:2571-2572`, defined `:1140-1142`) — so extraction ignores it; only a pass missing its required `:code` (`pngine/schema/pngine.sjon:2538-2540`) is a graph error.
- [ ] Scope fragment lookup to one `Program`; duplicate names produce a program error rather than last-wins behavior.
- [ ] Represent `:requires` as borrowed WGSL-name records with SJON spans.
- [ ] Detect an `(import …)` head and mark the program `unsupported_document_import`; do not build a partial graph.
- [ ] Run extraction tests with `std.testing.allocator`; all inventory rows pass.
- [ ] Commit: `feat: extract pngine shader graphs from SJON`.

### Task 4: Discovery and reverse membership

**Files:** `src/pngine/Discovery.zig`, `src/pngine/Store.zig`, `tests/pngine_discovery_test.zig`.

- [ ] Add red temp-tree tests for every `D*` inventory row.
- [ ] Implement workspace-root scanning, marker bundle expansion, ancestor fallback, dedupe by canonical document path, and bounded discovery.
- [ ] Treat malformed markers as unavailable candidate indexes; continue with direct `.sjon` candidates and report incomplete discovery.
- [ ] Build `canonical WGSL path → memberships` and `part → containing roots` indexes in stable path/form order.
- [ ] Preserve an explicitly marked last-known-good program on a transient syntax error; never use one after its document is deleted.
- [ ] Return distinct `none`, `complete`, `incomplete`, and `unsupported` discovery states.
- [ ] Run discovery tests; all pass without reading outside the fixture root except the explicit external-project case.
- [ ] Commit: `feat: discover WGSL membership in pngine projects`.

### Task 5: Overlay, content hash, and invalidation

**Files:** `src/pngine/Store.zig`, `lsp/Handler.zig`, `lsp/handler/incremental_sync.zig`, `tests/pngine_store_test.zig`.

- [ ] Write red tests proving open-text precedence, sibling overlays, selective invalidation, same-mtime content changes, and deletion.
- [ ] Store SHA-256 per source and program. Rehash after a refresh read; never use mtime as equality.
- [ ] Expose `Store.textForPart` returning the resolved `SourceText` (open buffer > injected > disk) with its content hash; D37/D38 cover it.
- [ ] Hook every open/change/incremental-change/close path into `Store.upsertBuffer` or `removeBuffer`.
- [ ] Invalidate only dependent root IDs on WGSL edits. SJON/marker edits rebuild only affected programs and the reverse index.
- [ ] Add `pngineEnabled()` using the new spec-driven LSP option; disabling returns an empty membership set and preserves legacy behavior.
- [ ] Run store, incremental-sync, and analysis-cache tests; all pass.
- [ ] Commit: `feat: cache pngine graphs with buffer overlays`.

### Task 6: Watchers and WASM source supply

**Files:** `lsp/NativeServer.zig`, `lsp/wasm.zig`, new WASM project adapter, `npm/wgslender-vscode/src/pngine-sync.ts`, both extension entry points, `npm/wgslender-vscode/src/client-options.ts`, `npm/wgslender-lsp/test.js`, `tests/pngine_transport_test.zig`.

- [ ] Add red native/WASM tests for watched SJON/WGSL changes, deletion, `pngineRead` missing files, and open-buffer precedence.
- [ ] Add a red no-watcher test: a client that never sends `workspace/didChangeWatchedFiles` still gets content-checked refresh at `didOpen`, `didSave`, and explicit project selection (D45).
- [ ] Route `workspace/didChangeWatchedFiles` into `Store.invalidatePath`; schedule affected open documents for later diagnostic refresh.
- [ ] Implement `wgslender/pngineCatalog` and `wgslender/pngineRead` without changing the npm package’s exported JavaScript API.
- [ ] In VS Code, catalog workspace SJON documents, answer `pngineRead` through `workspace.fs`, and register SJON/WGSL file events in the shared client options.
- [ ] Coalesce catalog changes; never send a snapshot on an ordinary WGSL keystroke.
- [ ] Run transport parity and `npm test` in `npm/wgslender-lsp`; native and WASM shapes agree and all tests pass.
- [ ] Commit: `feat: feed pngine project sources to both LSP transports`.

## Exhaustive use-case inventory

| ID | Fixture or synthetic input | Action | Expected result | Why phase 01 |
|---|---|---|---|---|
| D01 | `clock/program.sjon` | Discover `scene_lib.wgsl` | One `sceneLib` part; four fragment dependants and `sceneCode` are visible. | Corpus depth/shared-library baseline. |
| D02 | `clock/program.sjon` | Discover `clock_scene.wgsl` | Membership names `clockScene`; containing root is `sceneCode`. | Fragment-to-root indexing. |
| D03 | `clock/program.sjon` | Discover `scenes.wgsl` | Root membership for `sceneCode`; its four direct imports retain written order. | Root identity. |
| D04 | `demo/program.sjon` | Discover `palette.wgsl` | One part with roots `bgCode`, `squaresCode`, `postCode`, `compositeCode`. | Multi-root membership. |
| D05 | `bounce/program.sjon` | Discover `bouncing-sq.wgsl` | One no-import root. | No-import compatibility. |
| D06 | `veclock/program.sjon` | Discover `clock_vec.wgsl` | One no-import root. | Second no-import corpus case. |
| D07 | `veclock/kernels/circle.wgsl`, unreferenced | Discover | `none`, not a member by directory or name. | Reference-only membership. |
| D08 | Marker exists but no form references file | Discover | `none`. | Marker is not membership. |
| D09 | File outside every workspace, referenced by ancestor `program.sjon` | Discover | External membership is found without crossing filesystem root indefinitely. | Outside-workspace requirement. |
| D10 | Nested parent/child programs both reference file | Discover | Two sorted memberships, both retained. | Nested-project ambiguity. |
| D11 | Two documents in one project reference same file | Discover | Two part memberships with independent roots. | Candidate-document ambiguity. |
| D12 | Same form referenced through overlapping workspace roots | Discover | One canonical program/membership, not duplicates. | Multi-root workspace dedupe. |
| D13 | File used as fragment in program A and root in program B | Discover | Both roles survive. | Name/path role independence. |
| D14 | Two forms use same fragment name in different programs | Resolve imports | Each resolves locally. | Name-vs-path identity. |
| D15 | Duplicate fragment name in one valid program | Extract | Program graph error at second form; no last-wins table. | Graph integrity. |
| D16 | Inline `wgsl :code` imported by file root | Discover file root | Inline part exists in graph but creates no file membership. | `:code` model. |
| D17 | Inline `shader-module :code` | Extract | Root origin is inline with document/form/code spans. | Inline root identity. |
| D18 | Inline `pass :code :imports [f]` | Extract | Pass root and file membership for `f`; no synthetic post root. | Pass graph without lowering. |
| D19 | Pass without `:code` | Extract | Invalid root graph error. | Pass WGSL source is the required `:code` key; its `:file` is a data-file-list, not WGSL. |
| D20 | Fragment with both `:code` and `:file` | Extract | Invalid part; no arbitrary source choice. | Exclusive source forms. |
| D21 | Fragment with neither source key | Extract | Invalid part. | Required source. |
| D22 | Fragment with `:requires [noise]` | Extract | Requirement and SJON span retained. | Later hole diagnostics. |
| D23 | Unknown `:imports` name | Extract/index | Root carries unknown-import error; other programs remain usable. | Missing graph node. |
| D24 | Self-import, two-node cycle, diamond | Index graph | Cycle paths retained; diamond has two paths but one part identity. | Graph safety/dedupe input. |
| D25 | Missing referenced WGSL file | Discover | Membership survives with unreadable source status. | Missing-file handling. |
| D26 | Missing SJON candidate referenced by marker | Discover | Incomplete discovery naming the missing document. | Missing project file. |
| D27 | SJON syntax error on first load | Parse/discover | No typed membership from that document; state is incomplete. | Broken-project behavior. |
| D28 | Previously valid SJON becomes temporarily invalid | Refresh | Last-known-good graph is marked stale; content generation changes. | Editor recovery. |
| D29 | Invalid SJON is deleted | Watch/refresh | Program and last-known-good membership are removed. | Deletion correctness. |
| D30 | Malformed `sjon-lsp.sjon` | Discover | Direct candidates still considered; marker contributes no patterns. | Marker failure isolation. |
| D31 | Bundle glob and nested document path | Discover | Matching SJON candidates are loaded once. | Bundle semantics. |
| D32 | Symlinked WGSL path and real path | Discover both | Existing targets share membership; response retains caller URI. | Symlink identity. |
| D33 | `file:///C:/…`, UNC, and `%20` paths | Normalize | Correct native identity and valid URI round-trip. | Windows/file-URI requirement. |
| D34 | `Foo.wgsl` vs `foo.wgsl` | Lookup on target rules | Distinct on POSIX; folded under Windows identity rules. | Case-sensitivity contract. |
| D35 | `untitled:` or test URI | Discover | No filesystem access; only exact injected/open membership can match. | Non-file URI safety. |
| D36 | SJON `(import :file "base.sjon")` | Extract | `unsupported_document_import`; no partial assembled graph. | Fail-closed non-goal. |
| D37 | Open current WGSL differs from disk | Membership/source query | Open text and hash win. | Current unsaved buffer. |
| D38 | Open sibling differs from disk | Source query from another part | Sibling’s open text wins. | Cross-part unsaved buffers. |
| D39 | Closed file changes with unchanged mtime | Content-checked refresh | Hash mismatch invalidates dependents. | Why content, not mtime. |
| D40 | Edit unrelated file | Invalidate | Roots not containing it retain cache keys. | Incremental scope. |
| D41 | `lsp.pngine.enabled=false` | Open composed file | Store returns no project context; legacy path remains available. | Opt-out/degradation. |
| D42 | Discovery exceeds directory/document/byte cap | Discover | `incomplete`, explicit reason; never a false `none`. | Bounded hostile workspaces. |
| D43 | WASM host cannot supply a requested WGSL file | `pngineRead` response | Missing-source state; no empty synthetic WGSL. | WASM negative path. |
| D44 | WASM disk snapshot changes while document is open | Catalog/read then edit | Open buffer remains authoritative. | Transport overlay precedence. |
| D45 | Client never sends `workspace/didChangeWatchedFiles` | didOpen/didSave/explicit selection | Content-checked refresh at each boundary; memberships and dependent caches are current without any notification. | No-watcher fallback policy. |

## Red-first and gate commands

- Register each new suite through `addTestStep`; none is allowed to depend on `tests/exhaustive`.
- `zig build test -j1`: exit `0`, including all new `D01–D45` assertions and existing tests.
- `zig build lsp && zig build lsp-wasm`: both exit `0`.
- `zig build -Dlsp=false`: exits `0` with project symbols compiled out and no SJON dependency resolution.
- `(cd npm/wgslender-lsp && npm test)`: exit `0`.
- Store instrumentation test: after warm discovery, 200 WGSL edits cause **0 SJON parses and 0 discovery scans**.

## Stop-and-report conditions

- A required SJON AST accessor is not public or cannot retain author spans.
- The dependency cannot build native and WASM without libc.
- Correct bundle expansion would require loading executable plugins.
- Canonicalization cannot distinguish the Windows/UNC cases without changing existing URI behavior.
- Supporting an SJON `(import …)` fixture appears to work only because a partial graph was built; mark it unsupported instead.

## Risks

- **Workspace scan cost:** bounded and cached; explicit project selection is the fallback.
- **Stale graph during SJON syntax recovery:** visibly marked and replaced on the next valid refresh.
- **Filesystem identity differences:** isolated in `Path.zig` with target-specific tests.
- **WASM source round-trips:** requests are limited to referenced files and never occur per keystroke.
- **Graph-name collisions:** program-scoped tables and stable root IDs prevent cross-program capture.

---
