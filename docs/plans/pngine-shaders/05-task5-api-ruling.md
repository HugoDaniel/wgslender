# Phase 05 Task 5 API ruling

**Decision:** keep one compile-time gate, expose a small provider-driven Zig facade, and leave CLI selection policy in the CLI. This ruling is source-reviewed at `684ce64`; GitNexus coverage was unavailable.

## Q1 — absence is `void`, enforced in each graph

Choose **`pub const Pngine = if (build_options.pngine_support) @import("pngine/Pngine.zig") else void` plus per-graph compile checks**. `root.zig` is the only gate. `build.zig` must continue deriving the option from `sjon_mod != null` and wiring the `sjon` import in the same branch; it must not become an independent user option.

This makes every project declaration, including `Pngine.Store`, unavailable at compile time while leaving the source-only root usable. The conditional import is not analyzed in a project-free graph. An optional absent submodule would create a second build wiring decision, `@compileError` would punish merely importing the core root if placed at that boundary, and a runtime stub would falsely advertise callable project APIs. A contributor cannot half-enable support: enabling the option without SJON fails compilation, while supplying SJON without enabling the option is caught by the enabled/disabled graph checks.

Remove the redundant `Pngine.enabled` and its `build_options` import from the public facade; presence of the namespace is the answer. Keep `hasFormHead` out of the consumer API (it was dependency proof-of-life, not project functionality).

## Q2 — exports and graph matrix

| Build graph | `src/root.zig` result | Project exports |
|---|---|---|
| Native CLI and native LSP with SJON resolved; native tests | `Pngine = @import("pngine/Pngine.zig")` | The facade below |
| Native CLI with `-Dlsp=false` | `Pngine = void` | None |
| `wasm` | `Pngine = void` | None |
| `lib` and `lib-pic-check` | `Pngine = void` | None |
| `lsp-wasm` and WASM `release-assets` | `Pngine = void` | None |

No other root export changes. In particular, `validate`, `lint`, `reflect`, `minify`, `compile`, and their options keep their existing text-only signatures. npm, WASM, C, Go, and Rust gain no project entry point.

### Exact consumer facade in `src/pngine/Pngine.zig`

```zig
pub const Types = @import("Types.zig"); // provider/ID/part/overlay vocabulary
pub const Store = @import("Store.zig").Store;
pub const Program = Types.Program;
pub const ProgramId = Types.ProgramId;
pub const PartId = Types.PartId;
pub const RootId = @import("Assemble.zig").RootId;
pub const OriginKey = @import("Assemble.zig").OriginKey;
pub const ByteRange = @import("Mapping.zig").ByteRange;
pub const Assembled = @import("Assemble.zig").Assembled;
pub const OriginRange = @import("Mapping.zig").OriginRange;
pub const OriginOffset = @import("Mapping.zig").OriginOffset;
pub const LocatedLine = @import("Mapping.zig").LocatedLine;
pub const AssemblyError = @import("Assemble.zig").Error || error{
    UnknownProgram, UnknownPart, NotARoot,
};
pub const MappedDiagnostics = struct {
    items: []const @import("../Diagnostic.zig").Entry,
    _arena: std.heap.ArenaAllocator, // owns every item/string/related/fix/hint
    pub fn deinit(self: *MappedDiagnostics) void;
};
pub const SourceMapOptions = @import("SourceMaps.zig").Options;
pub const SourceMapError = std.mem.Allocator.Error || error{InvalidPartUri};
pub const RemappedSourceMap = struct {
    map: @import("../SourceMap.zig").Result,
    dropped: u32,
    _arena: std.heap.ArenaAllocator, // owns arrays and all strings, including names/file
    pub fn deinit(self: *RemappedSourceMap) void;
};

pub fn assembleRoot(store: *Store, root: RootId) AssemblyError!*const Assembled;
pub fn mapDiagnostics(
    gpa: std.mem.Allocator,
    store: *Store,
    assembled: *const Assembled,
    entries: []const @import("../Diagnostic.zig").Entry,
) std.mem.Allocator.Error!MappedDiagnostics;
pub fn remapSourceMap(
    gpa: std.mem.Allocator,
    store: *Store,
    assembled: *const Assembled,
    assembled_map: *const @import("../SourceMap.zig").Result,
    options: SourceMapOptions,
) SourceMapError!RemappedSourceMap;
```

`SourceMapOptions.file` and all inputs are borrowed only for the call. `mapDiagnostics` maps one already assembled root (`assembled.root`); it does not parse, validate, lint, add graph errors, or perform the CLI's multi-root policy. Unmappable input follows `Projection` policy and produces the context-incomplete warning rather than a fabricated location. `remapSourceMap` collects contributing origins through the same store, preserves generated positions/names, and reports omitted unmappable segments in `dropped`.

The existing `Extract`, `Discovery`, `Assemble`, `Mapping`, `SourceMaps`, `Analysis`, `Projection`, and `VirtualUri` aliases may remain solely for in-tree CLI/LSP/test compilation units. They are internal, carry no consumer compatibility promise, and Task 5 must not document them as additional public entry points or add LSP handler types.

### Ownership, input, and error contract required in Task 5 docs

| Item | Contract |
|---|---|
| `Types.SourceProvider` | Consumer supplies `context` plus static `VTable`; both outlive the store. `read_text` and `candidates` have `anyerror` provider errors. Each successful result, every `Candidate.path`, and the candidate slice are allocated with the passed allocator and become the callee's ownership; on failure the provider cleans up partial results. |
| `Store` | **Yes, provider construction is exposed exactly as `Store.init(gpa: Allocator, provider: Types.SourceProvider) Store`; no second convenience constructor.** It cannot fail. The caller owns the store and calls `store.deinit()` exactly once; the provider context is borrowed, not freed. Discovery methods may propagate provider errors or record incomplete discovery as already documented. |
| Store source methods | Paths/URIs and overlay text are borrowed for the call and copied when retained. Authority is **open buffer > provider-injected > provider text**. `textForPart` returns caller-owned `Types.SourceText`; call `deinit(store.gpa)`. Its failures are `OutOfMemory`, `UnknownPart`, `UnknownProgram`, or `SourceUnavailable`. |
| `Program`, IDs, mapping values | `Store.program`/`part` and all their strings are store-borrowed; never call `Program.deinit` on them. IDs/ranges are values with no allocation. Refresh or store destruction invalidates borrowed graph views. |
| `assembleRoot`, `Assembled` | Takes a logical ID, not text/path/provider. The store allocates and caches the unit; the caller must **not** call `Assembled.deinit`. The pointer remains valid until that root is invalidated or the store is deinitialized. Errors are exactly `AssemblyError`: OOM, unknown program/part, non-root, cycle, unknown fragment, limit/depth, or missing source. |
| `OriginRange`, `OriginOffset`, `LocatedLine` | Allocation-free mapping results; no deinit. Their IDs/ranges are author-local; any borrowed name remains tied to the assembled unit/store. |
| `mapDiagnostics`, `MappedDiagnostics` | Takes assembled-coordinate diagnostic text results, not paths. `assembled` must come from the same live store. The result deep-owns final author-local `Diagnostic.Entry` values and is independent of input entries and the store after return; call `deinit()` once. Only OOM is returned. |
| `remapSourceMap`, `RemappedSourceMap` | Takes an assembled map, not paths. The returned map deep-owns all arrays/strings and is independent of the store and input map; call `deinit()` once. Errors are OOM or `InvalidPartUri`; missing author content is represented by `dropped`, never a fake source. `SourceMapOptions` is a borrowed value. |

All exported `src/pngine` operations are filesystem-free: they accept no `std.Io`, open no project file, and enumerate no directory. A consumer binding supplies the provider; native CLI/`lsp/native` bindings perform filesystem work today, and a future WASM binding remains reserved. Logical provider paths are not proof of host filesystem access. The existing unexported `Path.zig` canonicalization helpers are outside this facade; docs must not turn this into a false claim that every file anywhere under `src/` contains no filesystem code.

### Helper and selection rulings

Expose the **one-shot helpers**, not just low-level objects: a third party should not reproduce `Projection.Report` ownership or the CLI's source collection to get honest author output. The owned result envelopes above are mandatory; returning bare `Projection.Result` or `SourceMap.Result` would hide borrowed lifetimes. Lower-level projection/source-collection orchestration remains internal.

**Do not export `selectProject` or `ProjectSelection` from `Pngine` in Task 5.** They stay in `cli/PngineSelection.zig`: `no_project`, stdin replacement, formatted usage failures, and exit-2 policy are CLI concerns. Their `input_path`/`project_path` strings are valid **logical provider-resolved paths**, not direct filesystem authority. A `PartId`-only API cannot replace them because selection is what discovers/mints those IDs. Selection may normalize lexically and call the provider, but must not open paths itself.

## Compile-test matrix

| Test/build | What it proves |
|---|---|
| Native `tests/pngine_api_test.zig` under `zig build test` | Every facade declaration compiles; an in-memory provider drives selection-free discovery, assembly, diagnostic mapping, and source-map ownership/deinit. |
| Native enabled compile check attached to `zig build` | Actual native CLI module has non-`void` `Pngine` and every facade declaration; source-only calls still compile unchanged. |
| The same enabled check attached to `zig build lsp` | Actual native LSP uses the same enabled `wgslender` module; no handler type is added to core. |
| `zig build -Dlsp=false` with project-free check against the actual native CLI module | `pngine_support == false`, `@TypeOf(wgslender.Pngine) == void`, and existing source-only calls compile; any `Pngine.Store` reference is necessarily a compile error. |
| `zig build wasm` with its in-graph project-free object | Real WASM graph is `void`/SJON-free and its source ABI compiles unchanged. |
| `zig build lib` with its in-graph project-free object | Real C-library options/target remain project-free and the C ABI source calls compile unchanged. |
| `zig build lsp-wasm` with the shared real wasm-module check | WASM LSP remains project-free; no project protocol/capability or SJON import appears. |
| Existing npm consumer tests | JS/WASM function signatures and single-source results do not change and trigger no discovery. |
| Existing C example build/tests | C ABI/header and source-only calls do not change. |
| Existing Go and Rust consumer build/tests | Their embedded/native paths need no provider, SJON, network, or new argument. |

Compile assertions prove per-graph type absence; the Task 6 empty-cache/no-SJON-fetch gates still prove dependency resolution. Do not replace either side with the other.

## Task 5 must NOT

- Add a runtime `error.PngineUnsupported` stub, a second support switch, or a root-level `@compileError`.
- Add path/provider/`std.Io` parameters to existing source-only functions or put a filesystem provider in `src/`.
- Export CLI selection/exit policy, LSP handlers, or new low-level project modules as supported consumer API.
- Return borrowed diagnostic/source-map data without one owning result and one documented `deinit` call.
- Change npm/WASM/C/Go/Rust APIs, package capabilities, or committed artifacts.
- Use an expected-failure consumer probe as a substitute for compiling the real enabled and project-free graphs.
