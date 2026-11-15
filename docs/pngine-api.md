# Wgslender pngine Zig API (experimental)

Zig-facing support for pngine shader projects: discover a project through a
source provider you supply, assemble one root, and map diagnostics and source
maps back onto the author files. Experimental — the shape may shift between
versions.

The reference consumer is [`tests/pngine_api_test.zig`](../tests/pngine_api_test.zig):
it drives discovery → `assembleRoot` → `mapDiagnostics` → `remapSourceMap`
through this facade alone with an in-memory provider, and pins the ownership
contract asserted below. Prefer copying from there over copying from here.

## Availability

```zig
pub const Pngine = if (build_options.pngine_support) @import("pngine/Pngine.zig") else void;
```

`src/root.zig` is the only gate, and `build.zig` derives the option from
whether the SJON dependency resolved (`sjon_mod != null`); it is not an
independent user option. There is no `Pngine.enabled` and no runtime "maybe"
mode — the presence of the namespace is the answer:

| Build graph | `wgslender.Pngine` |
|---|---|
| Native CLI and native LSP with SJON resolved; native tests | the facade below |
| `zig build -Dlsp=false` | `void` |
| `zig build wasm` | `void` |
| `zig build lib` | `void` |
| `zig build lsp-wasm` | `void` |

Each graph proves its own state at compile time (`tests/pngine_native_api_check.zig`
for the native graphs, `tests/pngine_project_free_check.zig` for the
project-free ones). Enabling the option without SJON fails the build; supplying
SJON without enabling it is caught by the same checks.

Nothing else in `root.zig` changes: `validate`, `lint`, `reflect`, `minify`,
`compile`, and their options keep their existing text-only signatures, and
npm, WASM, C, Go, and Rust gain no project entry point.

## Surface

```zig
pub const Types = …;          // provider/ID/part/overlay vocabulary
pub const Store = …;          // project store
pub const Program = Types.Program;
pub const ProgramId = Types.ProgramId;
pub const PartId = Types.PartId;
pub const RootId = …; pub const OriginKey = …;
pub const ByteRange = …; pub const Assembled = …;
pub const OriginRange = …; pub const OriginOffset = …; pub const LocatedLine = …;
pub const AssemblyError = …;
pub const MappedDiagnostics = struct { items: []const Diagnostic.Entry, _arena, deinit() };
pub const SourceMapOptions = …;
pub const SourceMapError = std.mem.Allocator.Error || error{InvalidPartUri};
pub const RemappedSourceMap = struct { map: SourceMap.Result, dropped: u32, _arena, deinit() };

pub fn assembleRoot(store: *Store, root: RootId) AssemblyError!*const Assembled;
pub fn mapDiagnostics(gpa, store, assembled, entries) Allocator.Error!MappedDiagnostics;
pub fn remapSourceMap(gpa, store, assembled, assembled_map, options) SourceMapError!RemappedSourceMap;
```

`selectProject`/`ProjectSelection` are deliberately **not** exported:
which project to act on, stdin replacement, formatted usage failures, and
exit-2 policy are CLI concerns and stay in `cli/PngineSelection.zig`.

## Ownership, input, and error contract

| Item | Contract |
|---|---|
| `Types.SourceProvider` | Consumer supplies `context` plus static `VTable`; both outlive the store. `read_text` and `candidates` have `anyerror` provider errors. Each successful result, every `Candidate.path`, and the candidate slice are allocated with the passed allocator and become the callee's ownership; on failure the provider cleans up partial results. |
| `Store` | `Store.init(gpa, provider)` is the single construction path; there is no second convenience constructor. It cannot fail. The caller owns the store and calls `store.deinit()` exactly once; the provider context is borrowed, not freed. Discovery methods may propagate provider errors or record incomplete discovery. |
| Store source methods | Paths/URIs and overlay text are borrowed for the call and copied when retained. Authority is **open buffer > provider-injected > provider text**. `textForPart` returns caller-owned `Types.SourceText`; call `deinit(store.gpa)`. Its failures are `OutOfMemory`, `UnknownPart`, `UnknownProgram`, or `SourceUnavailable`. |
| `Program`, IDs, mapping values | `Store.program`/`part` and all their strings are store-borrowed; never call `Program.deinit` on them. IDs/ranges are values with no allocation. Refresh or store destruction invalidates borrowed graph views. |
| `assembleRoot`, `Assembled` | Takes a logical ID, not text/path/provider. The store allocates and caches the unit; the caller must **not** call `Assembled.deinit`. The pointer remains valid until that root is invalidated or the store is deinitialized. Errors are exactly `AssemblyError`: OOM, unknown program/part, non-root, cycle, unknown fragment, limit/depth, or missing source. |
| `OriginRange`, `OriginOffset`, `LocatedLine` | Allocation-free mapping results; no deinit. Their IDs/ranges are author-local; any borrowed name remains tied to the assembled unit/store. |
| `mapDiagnostics`, `MappedDiagnostics` | Takes assembled-coordinate diagnostic entries (what a source-only call produced on `Assembled.text`), not paths. `assembled` must come from the same live store. The result deep-owns final author-local `Diagnostic.Entry` values — ranges, `origin.file/project/root`, related lists, fixes, hint payloads — and is independent of the input entries and the store after return; call `deinit()` once. Only OOM is returned. Unmappable input follows the projection policy: the entry is dropped and one `P0001` context-incomplete warning appears, never a fabricated location. |
| `remapSourceMap`, `RemappedSourceMap` | Takes an assembled map, not paths. Contributing origins are collected through the same store: file parts are named by the user's `:file` spelling, inline `:code` parts by their stable virtual URI. Generated positions and name indices are preserved verbatim. The returned map deep-owns all arrays/strings — `file`, `sources`, `sourcesContent`, `names`, `mappings` — and is independent of the store and input map after return; call `deinit()` once. Errors are OOM or `InvalidPartUri`; missing author content is represented by `dropped` (report it as one warning), never a fake source. `SourceMapOptions` and all inputs are borrowed only for the call. |

## Purity and providers

All exported `src/pngine` operations are filesystem-free: they accept no
`std.Io`, open no project file, and enumerate no directory. A consumer
binding supplies the provider; the native CLI and the `lsp/native` bindings
perform filesystem work today, and a future WASM binding remains reserved
(see the pngine-shaders plan README, "WASM project input contract"). Logical
provider paths are not proof of host filesystem access.

That statement is about this facade only. The unexported `Path.zig`
canonicalization helpers and the CLI/LSP bindings outside `src/pngine` are
outside it — this is not a claim that every file anywhere under `src/`
contains no filesystem code.

## Example

```zig
const wgslender = @import("wgslender");
const Pngine = wgslender.Pngine;

var store = Pngine.Store.init(gpa, my_provider);
defer store.deinit();

try store.setWorkspaceRoots(&.{"/my/project"});
const program_id = store.programForDocument("/my/project/program.sjon").?;
// … find the RootId for the root you want through store.program(id) …

const assembled = try Pngine.assembleRoot(&store, root); // store-owned; do not free

var validation = try wgslender.validate(gpa, @ptrCast(assembled.text)); // source-only call
defer validation.deinit();
var mapped = try Pngine.mapDiagnostics(gpa, &store, assembled, validation.diagnostics.diagnostics.items);
validation.deinit(); // input entries may die; `mapped` is independent
// … read mapped.items (author-local Diagnostic.Entry values) …
mapped.deinit();
```
