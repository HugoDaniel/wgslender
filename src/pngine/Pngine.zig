//! pngine shader-project support — the experimental consumer facade
//! (pngine-shaders phase 05, Task 5).
//!
//! Compiled into the graph only where the build resolved the SJON
//! dependency: `src/root.zig` gates this file behind
//! `build_options.pngine_support`, which `build.zig` derives from
//! `sjon_mod != null` on the native CLI/LSP/tests path and forces false
//! everywhere else. The `wasm`, `lib`, and `lsp-wasm` graphs and every
//! `-Dlsp=false` build see `void` from `root.Pngine` and never analyze
//! this file. The presence of this namespace is the answer to "is
//! project support compiled in": there is no `enabled` flag and no
//! runtime "maybe" mode to ask.
//!
//! ## What this namespace is
//!
//! The exports below are the experimental third-party surface settled by
//! `docs/plans/pngine-shaders/05-task5-api-ruling.md` and documented for
//! consumers in `docs/pngine-api.md`: the provider/ID vocabulary
//! (`Types`), the project `Store`, assembly and mapping values, and the
//! three entry points `assembleRoot`, `mapDiagnostics`, and
//! `remapSourceMap`. The `Extract`, `Discovery`, `Assemble`, `Mapping`,
//! `SourceMaps`, `Analysis`, `Projection`, and `VirtualUri` aliases that
//! follow them are **internal**: they exist so the in-tree CLI, LSP, and
//! test compilation units can share one implementation, they carry no
//! consumer compatibility promise, and they are not additional public
//! entry points. CLI selection policy (which project/root to act on,
//! stdin replacement, exit codes) stays in `cli/PngineSelection.zig` and
//! is deliberately not exported here.
//!
//! ## Provider and purity
//!
//! Every project read goes through the `Types.SourceProvider` the
//! consumer supplies at `Store.init`; both the provider and its context
//! outlive the store. All operations exported here are filesystem-free:
//! they accept no `std.Io`, open no project file, and enumerate no
//! directory. Logical provider paths are not proof of host filesystem
//! access. The native CLI and `lsp/native` bindings bind a filesystem
//! provider today; a WASM binding remains reserved (see the README's
//! "WASM project input contract"). This is a statement about this facade
//! only — the unexported `Path.zig` canonicalization helpers and the
//! CLI/LSP bindings outside `src/pngine` are outside it, so it must not
//! be repeated as a claim about every file under `src/`.
//!
//! ## Ownership contract (the short form; docs/pngine-api.md has the table)
//!
//! - `Store.init(gpa, provider)` is the single construction path and
//!   cannot fail; the caller owns the store and calls `store.deinit()`
//!   exactly once. The provider context is borrowed, never freed.
//! - `assembleRoot` takes a logical `RootId`, not a path or text. The
//!   store allocates and caches the unit; **the caller must not call
//!   `Assembled.deinit`** on the returned pointer. It stays valid until
//!   that root is invalidated or the store is deinitialized.
//! - `mapDiagnostics` and `remapSourceMap` are one-shot helpers over the
//!   internal projector and source-map engine. Each deep-owns its result
//!   in a private arena — independent of the input entries, the input
//!   map, and the store after return — and each is released with exactly
//!   one `deinit()` call. Unmappable input follows the projector's
//!   policy: the entry is dropped and one context-incomplete warning
//!   (`P0001`) is reported, or the mapping is counted in `dropped`;
//!   neither ever fabricates an author location.

const std = @import("std");

const Allocator = std.mem.Allocator;

const WgslDiagnostic = @import("../Diagnostic.zig");
const WgslSourceMap = @import("../SourceMap.zig");

// =========================================================================
// Consumer facade (experimental)
// =========================================================================

/// Graph vocabulary shared by extraction, discovery, and the store:
/// `SourceProvider`, `Program`, `Part`, IDs, overlays, and limits.
pub const Types = @import("Types.zig");

/// The project store: discovered programs, reverse membership, overlays,
/// invalidation, and the content-keyed assembly cache.
/// `Store.init(gpa, provider)` is the only construction path.
pub const Store = @import("Store.zig").Store;

/// One parsed `.sjon` document graph. `store.program(id)` borrows it;
/// never call `Program.deinit` on a store-borrowed value.
pub const Program = Types.Program;

/// Stable program slot in a `Store`. Slots are never reused.
pub const ProgramId = Types.ProgramId;

/// `(program, source-order part index)` — a part identity, not a name.
pub const PartId = Types.PartId;

/// A root's stable identity: program slot plus source-order part index.
pub const RootId = Assemble.RootId;

/// The part an assembled range came from; the key for origin mapping.
pub const OriginKey = Assemble.OriginKey;

/// A half-open byte range in either domain; the field's owner says which.
pub const ByteRange = Mapping.ByteRange;

/// An assembled module: the text wgslender analyzes, the pngine-compatible
/// line table, and the byte segments for bidirectional mapping. Store-owned
/// when it came from `assembleRoot`.
pub const Assembled = Assemble.Assembled;

/// A byte range plus the author part it belongs to. Allocation-free.
pub const OriginRange = Mapping.OriginRange;

/// An author-local byte offset and the part it belongs to. Allocation-free.
pub const OriginOffset = Mapping.OriginOffset;

/// A located assembled line: pngine's `locate` answer. Allocation-free.
pub const LocatedLine = Mapping.LocatedLine;

/// Every failure `assembleRoot` can report: out of memory, an unknown
/// program or part, a non-root part, an import cycle, an unknown import,
/// a bound/depth limit, or a part whose source could not be read.
pub const AssemblyError = Assemble.Error || error{
    UnknownProgram,
    UnknownPart,
    NotARoot,
};

/// Author-local diagnostics produced by `mapDiagnostics`. The arena owns
/// every item and every string, related list, fix, and hint payload in
/// them; the result is independent of the input entries and of the store
/// after return. Release with exactly one `deinit()`.
pub const MappedDiagnostics = struct {
    /// Mapped entries in projection order. Ranges and `origin` are
    /// author-local; unmappable input was dropped and answered with one
    /// `P0001` warning rather than a fabricated location.
    items: []const WgslDiagnostic.Entry,
    /// Owns everything `items` references. Do not touch directly.
    _arena: std.heap.ArenaAllocator,

    /// Release every item and string. Call exactly once.
    pub fn deinit(self: *MappedDiagnostics) void {
        self._arena.deinit();
        self.items = &.{};
    }
};

/// Borrowed options for `remapSourceMap`, mirroring the minifier's map
/// options: the output `file` name and whether `sourcesContent[]` is
/// emitted. Borrowed only for the call.
pub const SourceMapOptions = SourceMaps.Options;

/// Every failure `remapSourceMap` can report: out of memory, or an
/// inline part whose virtual source URI could not be minted.
pub const SourceMapError = Allocator.Error || error{InvalidPartUri};

/// An author-source map produced by `remapSourceMap`. The arena owns the
/// map's arrays and every string they reference — `file`, `sources`,
/// `sourcesContent`, `names`, and `mappings` — so the result is
/// independent of the store and of the input map after return. Release
/// with exactly one `deinit()`.
pub const RemappedSourceMap = struct {
    /// The remapped Source Map v3 result. Generated positions and name
    /// indices are preserved from the input map; source positions are
    /// author-local.
    map: WgslSourceMap.Result,
    /// Mappings with no honest author origin. Never fabricated: report
    /// this count as one warning, not one per mapping.
    dropped: u32,
    /// Owns everything `map` references. Do not touch directly.
    _arena: std.heap.ArenaAllocator,

    /// Release the map and every string it references. Call exactly once.
    pub fn deinit(self: *RemappedSourceMap) void {
        self._arena.deinit();
        self.map = .{};
    }
};

/// Assemble one root from its transitive parts. `root` is a logical ID,
/// not a path or text: the store resolves every reached part through the
/// provider and overlays, assembles, and caches the unit. The caller
/// must **not** call `Assembled.deinit` on the returned pointer; the
/// store owns it, and it stays valid until that root is invalidated or
/// the store is deinitialized. A cache hit performs no provider read.
///
/// - Complexity: linear in the root's transitive text on a miss; O(1)
///   mapping-table lookups otherwise.
/// - Errors: exactly `AssemblyError`.
pub fn assembleRoot(store: *Store, root: RootId) AssemblyError!*const Assembled {
    return store.assembleRoot(root);
}

/// Map assembled-coordinate diagnostic entries onto the author files of
/// the one already assembled root (`assembled.root`). This is the one-shot
/// form of the shared projection the CLI and LSP use: it does not parse,
/// validate, lint, add graph errors, or apply any multi-root policy —
/// feed it the entries a source-only call produced on `Assembled.text`.
/// Related information and fixes are projected independently; input that
/// has no honest author range is dropped and answered with one `P0001`
/// context-incomplete warning, never a fabricated location.
///
/// `assembled` must come from the same live store. The result deep-owns
/// final author-local `Diagnostic.Entry` values and is independent of the
/// input entries and the store after return; call `deinit()` once.
///
/// - Complexity: linear in entries plus their related/fix payloads.
/// - Errors: only `error.OutOfMemory`.
pub fn mapDiagnostics(
    gpa: Allocator,
    store: *Store,
    assembled: *const Assembled,
    entries: []const WgslDiagnostic.Entry,
) Allocator.Error!MappedDiagnostics {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var report = try Projection.Report.init(gpa, store, .{ .roots = &.{assembled.root} });
    defer report.deinit();
    report.semantic_root_count = 1;
    for (entries) |*entry| {
        // The projector resolves unavailable author sources internally
        // (`docFor` maps them to "no document" and drops the entry), so
        // only OOM escapes it at runtime — but Zig does not narrow the
        // catch switch, so the inferred set still names the store errors.
        // Answer any that ever do escape exactly the way the projector
        // answers them: record incomplete context and keep mapping,
        // never fail the whole call.
        report.addFromRoot(assembled, assembled.root, entry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => report.addIncomplete(@errorName(err)),
        };
    }
    var result = try report.finish();
    defer result.deinit(gpa);

    const items = try alloc.alloc(WgslDiagnostic.Entry, result.items.len);
    for (result.items, 0..) |item, index| {
        items[index] = try copyEntry(alloc, &report, item, assembled.root.program);
    }
    return .{ .items = items, ._arena = arena };
}

/// Remap a source map built against `Assembled.text` onto the author
/// origins that contributed the unit. Contributing origins are collected
/// through the same store: file parts are named by the user's `:file`
/// spelling, inline `:code` parts by their stable virtual URI, and
/// `sourcesContent[]` carries the current author text when requested.
/// Generated positions and name indices are preserved verbatim; a
/// mapping with no honest author origin is omitted and counted in
/// `dropped`, never given a fabricated source.
///
/// `assembled` must come from the same live store; `assembled_map` and
/// `options` are borrowed only for the call. The returned map deep-owns
/// all of its arrays and strings and is independent of the store and the
/// input map after return; call `deinit()` once.
///
/// - Complexity: linear in decoded mappings plus contributing origins.
/// - Errors: exactly `SourceMapError`.
pub fn remapSourceMap(
    gpa: Allocator,
    store: *Store,
    assembled: *const Assembled,
    assembled_map: *const WgslSourceMap.Result,
    options: SourceMapOptions,
) SourceMapError!RemappedSourceMap {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const sources = try collectSources(alloc, store, assembled);
    var remapped = try SourceMaps.remap(gpa, assembled, sources, assembled_map, options);
    defer remapped.deinit(gpa);

    const map = WgslSourceMap.Result{
        .version = remapped.map.version,
        .file = try alloc.dupe(u8, remapped.map.file),
        .sources = try dupeStrings(alloc, remapped.map.sources),
        .sources_content = try dupeStrings(alloc, remapped.map.sources_content),
        .names = try dupeStrings(alloc, remapped.map.names),
        .mappings = try alloc.dupe(u8, remapped.map.mappings),
    };
    return .{ .map = map, .dropped = remapped.dropped, ._arena = arena };
}

// =========================================================================
// Internal aliases — in-tree CLI/LSP/test compilation units only.
// No consumer compatibility promise; not additional public entry points.
// =========================================================================

/// Strict SJON → graph extraction.
pub const Extract = @import("Extract.zig");
/// Provider-only workspace/ancestor discovery.
pub const Discovery = @import("Discovery.zig");
/// Pure fragment assembly and its line/byte tables.
pub const Assemble = @import("Assemble.zig");
/// Bidirectional assembled↔author byte and line mapping.
pub const Mapping = @import("Mapping.zig");
/// Assembled→author source-map remapping engine.
pub const SourceMaps = @import("SourceMaps.zig");
/// Shared per-root analysis: assembled text to a retained
/// validator/lint analysis. Used by the native LSP and the CLI.
pub const Analysis = @import("Analysis.zig");
/// Shared composed diagnostic projection: mapped diagnostics, multi-root
/// merge, graph errors, and whole-unit lint policy.
pub const Projection = @import("Projection.zig");
/// Stable virtual-document URIs for inline `:code` parts.
pub const VirtualUri = @import("VirtualUri.zig");

// =========================================================================
// One-shot helper internals
// =========================================================================

/// Deep-copy one projected diagnostic into the result arena as a final
/// author-local `Diagnostic.Entry`. Every string the CLI's renderer would
/// borrow — origin paths, project document, root name, related messages,
/// fix text, hint payloads — is owned by the arena when this returns.
fn copyEntry(
    alloc: Allocator,
    report: *Projection.Report,
    item: Projection.DiagnosticOut,
    fallback_program: Types.ProgramId,
) Allocator.Error!WgslDiagnostic.Entry {
    var entry: WgslDiagnostic.Entry = .{
        .severity = item.severity,
        .code = try alloc.dupe(u8, item.code),
        .message = try alloc.dupe(u8, item.message),
        .spec_ref = try alloc.dupe(u8, item.spec_ref),
        .source = try alloc.dupe(u8, item.source),
        .data = try copyHint(alloc, item.data),
    };

    if (item.origin) |origin| {
        const start = report.originPosition(origin, item.range.start) orelse
            Projection.Position{ .line = 1, .column = 1 };
        const end = report.originPosition(origin, item.range.end) orelse start;
        entry.range = .{
            .start = .{ .offset = item.range.start, .line = start.line, .column = start.column },
            .end = .{ .offset = item.range.end, .line = end.line, .column = end.column },
        };
        entry.origin = .{
            .file = try alloc.dupe(u8, report.originPath(origin) orelse ""),
            .project = try alloc.dupe(u8, report.projectPath(origin.program) orelse ""),
            .root = try alloc.dupe(u8, if (item.roots.len > 0)
                (report.rootName(item.roots[0]) orelse "")
            else
                ""),
        };
    } else {
        // A project-level diagnostic (the P0001 context warning): it has
        // no author file, so it anchors on the project document.
        entry.range = .{
            .start = .{ .offset = 0, .line = 1, .column = 1 },
            .end = .{ .offset = 0, .line = 1, .column = 1 },
        };
        entry.origin = .{
            .file = try alloc.dupe(u8, report.projectPath(item.program orelse fallback_program) orelse ""),
            .project = "",
            .root = "",
        };
    }

    if (item.related.len > 0) {
        const related = try alloc.alloc(WgslDiagnostic.RelatedInfo, item.related.len);
        for (item.related, 0..) |relation, index| {
            const path: []const u8, const position = switch (relation.target) {
                .author => |author| .{
                    report.originPath(author.origin) orelse "",
                    report.originPosition(author.origin, author.range.start) orelse
                        Projection.Position{ .line = 1, .column = 1 },
                },
                .project => |project| .{
                    report.projectPath(project.program) orelse "",
                    report.projectPosition(project.program, project.range.start) orelse
                        Projection.Position{ .line = 1, .column = 1 },
                },
            };
            related[index] = .{
                .file = try alloc.dupe(u8, path),
                .range = .{
                    .start = .{
                        .offset = switch (relation.target) {
                            .author => |author| author.range.start,
                            .project => |project| project.range.start,
                        },
                        .line = position.line,
                        .column = position.column,
                    },
                },
                .message = try alloc.dupe(u8, relation.message),
            };
        }
        entry.related = related;
    }

    if (item.fix) |fix| {
        const start = report.originPosition(fix.origin, fix.range.start) orelse
            Projection.Position{ .line = 1, .column = 1 };
        const end = report.originPosition(fix.origin, fix.range.end) orelse start;
        const owned = try alloc.create(WgslDiagnostic.Fix);
        owned.* = .{
            .range = .{
                .start = .{ .offset = fix.range.start, .line = start.line, .column = start.column },
                .end = .{ .offset = fix.range.end, .line = end.line, .column = end.column },
            },
            .text = try alloc.dupe(u8, fix.text),
        };
        entry.fix = owned;
    }

    return entry;
}

/// Deep-copy a quick-fix hint payload. The projector's hint strings are
/// owned by its `Report`; the facade's copies must outlive it.
fn copyHint(
    alloc: Allocator,
    data: WgslDiagnostic.QuickFixHint,
) Allocator.Error!WgslDiagnostic.QuickFixHint {
    return switch (data) {
        .none, .duplicate_location, .vertex_missing_builtin_position => data,
        .did_you_mean => |s| .{ .did_you_mean = try alloc.dupe(u8, s) },
        .unused_symbol => |s| .{ .unused_symbol = try alloc.dupe(u8, s) },
        .feature_not_enabled => |s| .{ .feature_not_enabled = try alloc.dupe(u8, s) },
        .type_mismatch => |tm| .{ .type_mismatch = .{
            .actual = try alloc.dupe(u8, tm.actual),
            .expected = try alloc.dupe(u8, tm.expected),
        } },
        .lint_fix => |lf| .{ .lint_fix = .{
            .start_line = lf.start_line,
            .start_character = lf.start_character,
            .end_line = lf.end_line,
            .end_character = lf.end_character,
            .text = try alloc.dupe(u8, lf.text),
        } },
    };
}

/// Name every origin the assembled unit can reference, exactly as the
/// CLI's source-map path names them: the user's `:file` spelling for
/// file parts, the stable virtual URI for inline `:code` parts. An
/// origin whose text the store cannot currently resolve contributes no
/// source, so `SourceMaps.remap` counts its mappings in `dropped`
/// instead of inventing one. Strings are allocated in `alloc` (the
/// result arena) and borrowed only for the call.
fn collectSources(
    alloc: Allocator,
    store: *Store,
    assembled: *const Assembled,
) SourceMapError![]SourceMaps.Source {
    var out: std.ArrayList(SourceMaps.Source) = .empty;
    for (assembled.segments) |segment| {
        const origin = segment.origin;
        var already = false;
        for (out.items) |existing| {
            if (existing.origin.program == origin.program and existing.origin.index == origin.index) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const part = store.part(origin) orelse continue;
        const program = store.program(origin.program) orelse continue;

        var text = store.textForPart(origin) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // An unreadable source has no author content to name; its
            // mappings become drops, never a fake source.
            else => continue,
        };
        defer text.deinit(store.gpa);
        const content = try alloc.dupe(u8, text.text);

        const name = switch (part.origin) {
            // The user's spelling, not the resolved path: a project's
            // `:file` is relative to its document and is what the editor
            // and the user call the file.
            .file => |file| try alloc.dupe(u8, file.path),
            .inline_code => try VirtualUri.encode(
                alloc,
                program.document_path,
                origin.index,
                Types.contentHash(content),
            ),
        };

        try out.append(alloc, .{
            .origin = origin,
            .name = name,
            .content = content,
        });
    }

    return out.toOwnedSlice(alloc);
}

/// Deep-copy a string-slice array into `alloc`.
fn dupeStrings(alloc: Allocator, strings: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, strings.len);
    for (strings, 0..) |value, index| {
        out[index] = try alloc.dupe(u8, value);
    }
    return out;
}
