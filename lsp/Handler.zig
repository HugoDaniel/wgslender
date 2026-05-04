//! WGSL Language Server — shared handler logic.
//!
//! Transport-agnostic core used by both the native (stdio) and WASM
//! entry points. Manages open documents, runs wgslender validation,
//! and converts diagnostics to a simple LSP-compatible format.
//!
//! This module has NO dependency on lsp-kit so it compiles for WASM.

const std = @import("std");
const wgslender = @import("wgslender");

const WgslDiagnostic = wgslender.Diagnostic;
const MinifySettings = wgslender.MinifySettings;
const MinifyEstimator = wgslender.MinifyEstimator;
const Ast = wgslender.Ast;
const Edits = wgslender.Edits;
const Lexer = wgslender.Lexer;
const Builtins = wgslender.Builtins;

const Handler = @This();

/// Per-document `MinifyEstimator` cache. Phase 7 (master plan §10): the
/// estimator runs through the production Printer and is non-trivial on
/// large shaders. Every estimator-using site (`collectMinifyHints`,
/// `appendTotalSizeLens`, the M0500 lint rule via `Linter.Options`) hits
/// this cache instead of allocating a fresh arena per call, so a 100-edit
/// burst followed by one refresh ≈ one estimator run total (vs. ~100
/// before the cache).
///
/// Cache key is `(module_version, options)`:
///   * `module_version` matches `Document.parse.?.module_version` at
///     compute time. Any reparse that bumps the version invalidates.
///   * `options` is compared by struct equality so the three default-
///     options sites (`Options{}`) share a slot, while the
///     `runShowMinifiedOutput` cold path (different options) bypasses
///     the cache.
///
/// The result lives in `arena`; teardown frees the hashmaps in one shot.
pub const MinifyCache = struct {
    arena: std.heap.ArenaAllocator,
    module_version: u32,
    options: MinifyEstimator.Options,
    result: MinifyEstimator.EstimateResult,

    fn deinit(self: *MinifyCache) void {
        self.arena.deinit();
    }
};

gpa: std.mem.Allocator,
documents: std.StringHashMapUnmanaged(Document),
/// Project-config layer — seeded from `wgslender.json` via `Config.discover`
/// in `discoverProjectConfig`. Empty until the LSP entry point calls it
/// (native does; WASM has no fs).
project_config: wgslender.Config = .{},
/// Workspace-overrides layer — replaced wholesale on every
/// `workspace/configuration` push via `applyClientConfig`. Schema is
/// identical to `wgslender.json`'s, so the same key set works in both
/// places (e.g. `lsp.minifyMode`, `rules.no-unused-vars`).
workspace_config: wgslender.Config = .{},

pub const Document = struct {
    source: []u8,
    version: i32,
    /// Cached analysis result. Invalidated on document change/close.
    analysis: ?*wgslender.Validator.AnalysisResult = null,
    /// Sentinel-terminated source used by the analysis. Written only by
    /// the slow fallback path in `analyzeDocument` (when `doc.parse` is
    /// unavailable and we must re-tokenize + re-parse from scratch). The
    /// fast path pulls a live sentinel-terminated source straight out of
    /// `doc.parse.?.source`, which is arena-owned and stable for as long
    /// as `doc.parse` stays put.
    analysis_source: ?[:0]u8 = null,
    /// `parse.module_version` captured at the moment `doc.analysis` was
    /// computed. The cache is hot iff `analysis != null`, `parse != null`,
    /// and this field matches the current `parse.module_version`. Any
    /// mismatch signals that the module's symbol table, AST nodes, or
    /// expression offsets have moved and the cached type/expr/const maps
    /// are stale.
    analysis_module_version: u32 = 0,
    /// Persistent parse state (source + AST + CST) kept fresh across
    /// `didChange` edits via `Incremental.reparse`. Consumed directly by
    /// `analyzeDocument` to skip re-tokenize + re-parse when valid.
    /// `null` if initial parse failed.
    parse: ?wgslender.Incremental.ReparseResult = null,
    /// Per-document magic-comment layer for minifier-mode resolution.
    /// Refreshed on `openDocument` / `changeDocument*` via `rebuildMagic`.
    /// `MinifySettings.Partial` is POD (no heap tail), so the cached
    /// value survives arena teardown in `rebuildMagic` without copying.
    magic_minify: MinifySettings.Partial = .{},
    /// Cached `MinifyEstimator` result for the current parse + options.
    /// Populated lazily by `getMinifyEstimate`. Invalidated by every path
    /// that bumps `parse.module_version` (didChange / didOpen / didClose
    /// re-open) and by minify-settings or magic-comment changes that
    /// could shift the resolved options.
    minify_cache: ?MinifyCache = null,
};

// =========================================================================
// LSP-compatible diagnostic (no lsp-kit dependency)
// =========================================================================

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

pub const DiagnosticSeverity = enum(u32) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const LspRelatedInfo = struct {
    range: Range,
    message: []const u8,
};

pub const DiagnosticTag = enum(u8) {
    unnecessary = 1,
    deprecated = 2,
};

pub const LspDiagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    code: []const u8 = "",
    spec_url: []const u8 = "",
    related: []const LspRelatedInfo = &.{},
    tags: []const DiagnosticTag = &.{},
};

pub const LspTextEdit = struct {
    range: Range,
    new_text: []const u8,
};

pub const LspCodeAction = struct {
    title: []const u8,
    kind: []const u8, // "quickfix"
    is_preferred: bool = false,
    diagnostic: LspDiagnostic,
    edits: []const LspTextEdit,
};

/// Server capabilities as a JSON string (shared by native and WASM).
pub const capabilities_json =
    \\{"textDocumentSync":{"openClose":true,"change":2,"save":{"includeText":false}},"positionEncoding":"utf-16","codeActionProvider":{"codeActionKinds":["quickfix"]},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"renameProvider":{"prepareProvider":true},"completionProvider":{"triggerCharacters":[".","@"]},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentSymbolProvider":true,"foldingRangeProvider":true,"typeDefinitionProvider":true,"inlayHintProvider":true,"codeLensProvider":{},"documentFormattingProvider":true,"semanticTokensProvider":{"full":true,"legend":{"tokenTypes":["keyword","function","struct","parameter","variable","number","type","comment","decorator"],"tokenModifiers":["declaration","readonly","defaultLibrary"]}},"selectionRangeProvider":true,"callHierarchyProvider":true,"documentHighlightProvider":true,"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false},"executeCommandProvider":{"commands":["wgslender.setMinifyMode","wgslender.toggleMinifyMode","wgslender.recomputeMinifyInsights"]}}
;

/// Creates a handler with an empty document store.
pub fn init(gpa: std.mem.Allocator) Handler {
    return .{
        .gpa = gpa,
        .documents = .empty,
    };
}

/// Frees all tracked documents and their sources.
pub fn deinit(self: *Handler) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.analysis) |a| {
            a.deinit(self.gpa);
            self.gpa.destroy(a);
        }
        if (entry.value_ptr.analysis_source) |s| {
            self.gpa.free(s);
        }
        if (entry.value_ptr.parse) |*p| {
            p.deinit();
        }
        if (entry.value_ptr.minify_cache) |*c| c.deinit();
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.source);
    }
    self.documents.deinit(self.gpa);

    self.project_config.deinit(self.gpa);
    self.workspace_config.deinit(self.gpa);
}

pub fn invalidateAnalysis(self: *Handler, uri: []const u8) void {
    const doc = self.documents.getPtr(uri) orelse return;
    self.invalidateAnalysisAt(doc);
}

pub fn invalidateAnalysisAt(self: *Handler, doc: *Document) void {
    if (doc.analysis) |a| {
        a.deinit(self.gpa);
        self.gpa.destroy(a);
        doc.analysis = null;
    }
    if (doc.analysis_source) |s| {
        self.gpa.free(s);
        doc.analysis_source = null;
    }
    doc.analysis_module_version = 0;
    invalidateMinifyCacheAt(doc);
}

/// Drop the per-document `MinifyEstimator` cache. Free function so paths
/// that don't have `*Handler` (only the `Document`) can call it.
fn invalidateMinifyCacheAt(doc: *Document) void {
    if (doc.minify_cache) |*c| {
        c.deinit();
        doc.minify_cache = null;
    }
}

/// Drop every document's minify-estimator cache. Called whenever a
/// settings layer that could shift `effectiveMinifyFor(uri)` changes —
/// the resolved `MinifyEstimator.Options` flow into the cache key, so
/// stale entries can no longer be trusted.
fn invalidateAllMinifyCaches(self: *Handler) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| invalidateMinifyCacheAt(entry.value_ptr);
}

/// (Re)build the persistent `doc.parse` from `doc.source`. Best-effort:
/// on failure (e.g. OOM) leaves `doc.parse = null` and returns. The LSP
/// continues to work via the full-reparse path in `analyzeDocument`.
pub fn rebuildParse(self: *Handler, doc: *Document) void {
    if (doc.parse) |*p| {
        p.deinit();
        doc.parse = null;
    }
    const result = wgslender.Incremental.parseFull(self.gpa, doc.source) catch return;
    doc.parse = result;
}

/// (Re)scan `doc.source` for magic-comment directives and cache the
/// resulting `Partial`. The scan runs on a transient arena so the M0000
/// diagnostics it emits are discarded; later phases surface them through
/// the publish/pull diagnostic paths via a dedicated scan at query time.
pub fn rebuildMagic(self: *Handler, doc: *Document) void {
    // Magic comments contribute to `effectiveMinifyFor`, so any change to
    // the magic layer can shift the resolved `MinifyEstimator.Options`
    // and must drop the cached estimate.
    invalidateMinifyCacheAt(doc);
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const result = wgslender.MagicComment.scan(arena_state.allocator(), doc.source) catch {
        doc.magic_minify = .{};
        return;
    };
    doc.magic_minify = result.partial;
}

// =========================================================================
// Document management
// =========================================================================

/// Registers a new document (or replaces an existing one) with the given source text.
pub fn openDocument(self: *Handler, uri: []const u8, text: []const u8, version: i32) !void {
    const new_source = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(new_source);

    const gop = try self.documents.getOrPut(self.gpa, uri);
    if (gop.found_existing) {
        // Re-open on an already-tracked URI. Tear down cache + parse +
        // source before overwriting the Document struct, otherwise the
        // old analysis arena, sentinel source, and CST/AST leak (and
        // future incremental edits that read stale pointers would be
        // operating on orphaned state).
        self.invalidateAnalysisAt(gop.value_ptr);
        if (gop.value_ptr.parse) |*p| {
            p.deinit();
        }
        self.gpa.free(gop.value_ptr.source);
    } else {
        gop.key_ptr.* = try self.gpa.dupe(u8, uri);
    }
    gop.value_ptr.* = .{ .source = new_source, .version = version };
    self.rebuildParse(gop.value_ptr);
    self.rebuildMagic(gop.value_ptr);
}

/// Replaces the source text of an already-open document.
pub fn changeDocument(self: *Handler, uri: []const u8, text: []const u8) !void {
    self.invalidateAnalysis(uri);
    const doc = self.documents.getPtr(uri) orelse return;
    const new_source = try self.gpa.dupe(u8, text);
    self.gpa.free(doc.source);
    doc.source = new_source;
    // `parseFull` in `rebuildParse` starts fresh at `module_version = 0`.
    // Preserve monotonicity across the full-replace path so pull-mode
    // `resultId` values keep advancing — otherwise a client would see
    // the same id after a full-text edit and wrongly trust a stale
    // diagnostic set.
    const prev_version = if (doc.parse) |*p| p.module_version else 0;
    self.rebuildParse(doc);
    if (doc.parse) |*p| p.module_version = prev_version +% 1;
    self.rebuildMagic(doc);
}

/// Removes a document and frees its source and URI.
pub fn closeDocument(self: *Handler, uri: []const u8) void {
    self.invalidateAnalysis(uri);
    const entry = self.documents.fetchRemove(uri) orelse return;
    var value = entry.value;
    if (value.parse) |*p| {
        p.deinit();
    }
    if (value.minify_cache) |*c| c.deinit();
    self.gpa.free(entry.key);
    self.gpa.free(value.source);
}

pub fn getDocumentSource(self: *const Handler, uri: []const u8) ?[]const u8 {
    const doc = self.documents.get(uri) orelse return null;
    return doc.source;
}

/// Returns a revision key for pull-mode diagnostics (LSP `resultId`).
/// Two successive pulls that return the same value describe the same
/// diagnostic set — the server may reply with `Unchanged` in that case.
///
/// The key is `doc.parse.module_version`: bumped on every reparse that
/// could shift diagnostics, preserved by the trivia-only shortcut, and
/// kept monotonic across full-text replaces by `changeDocument`.
/// Returns `null` for unknown URIs or when the initial parse failed.
pub fn currentResultId(self: *const Handler, uri: []const u8) ?u32 {
    const doc = self.documents.get(uri) orelse return null;
    const p = doc.parse orelse return null;
    return p.module_version;
}

/// Handles a `textDocument/didSave` notification. The client remains the
/// authoritative source of text, so there is nothing to persist here — the
/// transport layer re-publishes diagnostics on top of this call. Kept as an
/// explicit hook point for future save-only behavior (e.g. format-on-save).
pub fn handleDidSave(self: *Handler, uri: []const u8) void {
    _ = self;
    _ = uri;
}

/// Walk parents from `start_dir` (or cwd when `null`) for a `wgslender.json`
/// and load it into `self.project_config`. Best-effort: any IO / parse
/// failure leaves `self.project_config` empty. Native-only — the WASM
/// entry has no filesystem and skips this call entirely.
pub fn discoverProjectConfig(self: *Handler, io: std.Io, start_dir: ?[]const u8) void {
    self.project_config.deinit(self.gpa);
    self.project_config = wgslender.Config.discover(self.gpa, io, start_dir) orelse .{};
    // The resolved minify state may have shifted now that the project
    // layer is non-empty; drop any caches keyed against the old empty
    // config. Cheap because `discoverProjectConfig` runs once at startup
    // before any documents are open.
    self.invalidateAllMinifyCaches();
}

/// Replace `self.workspace_config` with the contents of a fresh client
/// settings push. Schema is `wgslender.json`'s schema verbatim — set a
/// key in the file and the same key works under
/// `workspace/configuration` with identical semantics. Parse failures
/// (malformed JSON tree, OOM mid-parse) leave the workspace config
/// empty rather than half-applied — same permissive shape as
/// `Config.parseJson` and the rest of the LSP settings paths.
pub fn applyClientConfig(self: *Handler, value: std.json.Value) void {
    // Any settings refresh can shift `effectiveMinifyFor` — invalidate
    // once per configuration pull, far cheaper than a per-field dirty
    // check.
    self.invalidateAllMinifyCaches();
    self.workspace_config.deinit(self.gpa);
    self.workspace_config = .{};
    wgslender.Config.applyJsonValue(self.gpa, value, &self.workspace_config) catch {
        self.workspace_config.deinit(self.gpa);
        self.workspace_config = .{};
    };
}

/// Resolve the effective minifier-mode state for callers without a
/// document context (e.g. command handlers that act on the whole server).
/// The magic-comment layer is empty here — feature paths that operate on
/// a specific document must use `effectiveMinifyFor(uri)` instead.
pub fn effectiveMinify(self: *const Handler) MinifySettings.Effective {
    return MinifySettings.resolve(self.project_config.lsp_minify, self.workspace_config.lsp_minify, .{});
}

/// Resolve the effective minifier-mode state for a specific document.
/// Merges project → workspace → per-document magic-comment layers in
/// precedence order. Falls back to `effectiveMinify()` when `uri` is
/// unknown so callers can treat the accessor as total.
pub fn effectiveMinifyFor(self: *const Handler, uri: []const u8) MinifySettings.Effective {
    const magic: MinifySettings.Partial = if (self.documents.get(uri)) |doc|
        doc.magic_minify
    else
        .{};
    return MinifySettings.resolve(self.project_config.lsp_minify, self.workspace_config.lsp_minify, magic);
}

/// Resolve `lsp.inlayHints.enabled`. Defaults to `true` when neither
/// layer set it.
pub fn inlayHintsEnabled(self: *const Handler) bool {
    return self.workspace_config.lsp_inlay_hints_enabled orelse
        self.project_config.lsp_inlay_hints_enabled orelse
        true;
}

/// Resolve `lsp.diagnostics.enabled`. Defaults to `true` when neither
/// layer set it.
pub fn diagnosticsEnabled(self: *const Handler) bool {
    return self.workspace_config.lsp_diagnostics_enabled orelse
        self.project_config.lsp_diagnostics_enabled orelse
        true;
}

/// Resolve the single `mangleExternalBindings` knob, layered workspace →
/// project → false. The same value drives the LSP M0100 hint gate, the
/// estimator cache key, and `runShowMinifiedOutput` — and the local CLI
/// minifier reads `Minifier.Options.mangle_external_bindings` straight off
/// the same `Config` field, so editor and CLI behavior never diverge.
///
/// Magic comments don't contribute today (`MagicComment.zig` only emits
/// `mode`); if a future directive needs to override per-document, add it
/// to the Partial and merge here.
pub fn mangleExternalBindings(self: *const Handler) bool {
    return self.workspace_config.mangle_external_bindings orelse
        self.project_config.mangle_external_bindings orelse
        false;
}

/// Append the merged `rules` overrides from project + workspace into
/// `into`. Workspace entries win over project entries on duplicate id.
/// The caller (today: `lsp/handler/diagnostics.zig`) layers M0100 /
/// M0500 option gates on top before passing to the Linter.
pub fn appendLintRuleOverrides(
    self: *const Handler,
    arena: std.mem.Allocator,
    into: *std.StringHashMapUnmanaged(WgslDiagnostic.Severity),
) error{OutOfMemory}!void {
    inline for (.{ &self.project_config, &self.workspace_config }) |cfg| {
        for (cfg.lint_rules) |r| try into.put(arena, r.id, r.severity);
    }
}

// =========================================================================
// workspace/executeCommand — see lsp/handler/commands.zig
// =========================================================================

pub const Commands = @import("handler/commands.zig");
pub const CommandError = Commands.CommandError;
pub const MinifyCommandResult = Commands.MinifyCommandResult;
pub const ReflectCommandResult = Commands.ReflectCommandResult;
pub const executeCommand = Commands.executeCommand;
pub const runShowMinifiedOutput = Commands.runShowMinifiedOutput;
pub const runReflect = Commands.runReflect;

/// Returns cached analysis result for a document, running analysis if needed.
/// The returned pointer is owned by the Handler and valid until the document
/// is changed or closed.
///
/// Fast path: when `doc.parse` is populated and its `module_version` matches
/// the cached analysis's version, returns the cache untouched. Otherwise
/// runs `Validator.analyze` directly against `doc.parse.module`, skipping
/// the full Lexer + Parser pipeline. Only when `doc.parse` is unavailable
/// (initial parse OOM, reparse error) does the fallback path do a scratch
/// `analyzeWithOptions` run against a duped source buffer.
pub fn analyzeDocument(self: *Handler, uri: []const u8) !*wgslender.Validator.AnalysisResult {
    const doc = self.documents.getPtr(uri) orelse return error.DocumentNotFound;

    // Cache hit: the parse the cache was computed against is still current.
    if (doc.analysis) |a| {
        if (doc.parse) |*p| {
            if (doc.analysis_module_version == p.module_version) return a;
        } else {
            // No parse to compare against — treat as hot (legacy fallback
            // cache, valid until something explicitly invalidates).
            return a;
        }
        self.invalidateAnalysisAt(doc);
    }

    if (doc.parse == null) self.rebuildParse(doc);

    if (doc.parse) |*p| {
        return self.analyzeFromParse(doc, p);
    }

    return self.analyzeFromScratch(doc);
}

/// Fast path: run Validator directly against the live CST-lowered AST.
/// The AnalysisResult's arena holds only diagnostics + type caches; the
/// module itself lives in `parse.arena` and outlives the cache only until
/// the next `prev.deinit()` in `updateParseAfterEdit`, which always calls
/// `invalidateAnalysisAt` before tearing down.
fn analyzeFromParse(
    self: *Handler,
    doc: *Document,
    parse: *wgslender.Incremental.ReparseResult,
) !*wgslender.Validator.AnalysisResult {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var analyzed = try wgslender.Validator.analyze(alloc, parse.module, .{});

    // Merge parser + visit-pass errors (E0001/E0004/E0101/E0102/E0401)
    // into the validator's diagnostics. Mirrors the slow path at
    // src/root.zig:179-187 so both entry points produce identical sets.
    for (parse.errors) |err| {
        const end = if (err.end > err.pos) err.end else err.pos + 1;
        if (err.code.len > 0) {
            analyzed.diagnostics.addErrorWithCodeRange(alloc, err.pos, end, err.code, err.message);
        } else {
            analyzed.diagnostics.addErrorRange(alloc, err.pos, end, err.message);
        }
        analyzed.valid = false;
    }

    // DCE writes `is_live` flags on module.symbols. Reset first so
    // repeated analyze calls on the same module don't accumulate
    // incorrect liveness (e.g., a symbol that became unreachable after
    // an edit must see its prior `is_live = true` cleared).
    // B.M3: also allocate a fresh Liveness side-table per analyze;
    // a fresh allocation is implicitly zero so no separate reset
    // path is needed for the side-table — only the legacy field needs
    // explicit clearing. Side-table is discarded today (B.M4 wires it
    // onto AnalysisResult).
    for (parse.module.symbols.items) |*sym| {
        sym.flags.is_live = false;
    }
    if (wgslender.Liveness.init(parse.arena.allocator(), parse.module.symbols.items.len)) |liveness_init| {
        var liveness = liveness_init;
        _ = wgslender.Dce.mark(parse.arena.allocator(), parse.module, &liveness) catch {};
    } else |_| {}

    analyzed._arena = arena;

    const result = try self.gpa.create(wgslender.Validator.AnalysisResult);
    errdefer self.gpa.destroy(result);
    result.* = analyzed;

    doc.analysis = result;
    doc.analysis_module_version = parse.module_version;
    // `analysis_source` intentionally left null — the live source is
    // parse.source, which outlives this cache.
    return result;
}

/// Slow fallback: used only when `doc.parse` is unavailable (initial
/// parse OOM'd or a reparse failure dropped it and the subsequent
/// rebuild also failed). Behavior matches the pre-wiring path exactly.
fn analyzeFromScratch(
    self: *Handler,
    doc: *Document,
) !*wgslender.Validator.AnalysisResult {
    const source_z = try self.gpa.dupeZ(u8, doc.source);
    errdefer self.gpa.free(source_z);

    const result = try self.gpa.create(wgslender.Validator.AnalysisResult);
    errdefer self.gpa.destroy(result);
    result.* = try wgslender.analyzeWithOptions(self.gpa, source_z, .{});
    if (result.module) |module| {
        if (result._arena) |*arena| {
            // B.M3: allocate side-table mirror; discarded today.
            const aa = arena.allocator();
            if (wgslender.Liveness.init(aa, module.symbols.items.len)) |liveness_init| {
                var liveness = liveness_init;
                _ = wgslender.Dce.mark(aa, module, &liveness) catch {};
            } else |_| {}
        }
    }
    doc.analysis = result;
    doc.analysis_source = source_z;
    // No parse to key against; leave analysis_module_version at its
    // default (0). `analyzeDocument`'s cache-hit branch handles the
    // "no parse" case by returning the cache unconditionally.
    return result;
}

// =========================================================================
// MinifyEstimator cache
// =========================================================================

/// Errors `getMinifyEstimate` and `refreshMinifyInsights` can surface.
/// Three failure modes: the doc is unknown, the analysis didn't yield a
/// module (parser fully failed), or the cache allocator ran out.
pub const MinifyEstimateError = error{
    DocumentNotFound,
    NoModule,
    OutOfMemory,
};

/// Return the cached `MinifyEstimator.EstimateResult` for `uri`, computing
/// it on demand if the cache is cold or stale. The pointer is owned by
/// the document's cache arena and stays valid until the cache is
/// invalidated (next parse-version bump, settings refresh, magic-comment
/// rescan, document close, or handler deinit).
///
/// Cache-hit conditions: the doc has a populated cache whose
/// `module_version` matches the live `parse.module_version` AND whose
/// `options` are byte-identical to the requested ones. Any miss replaces
/// the entry with a fresh estimate; cache state is single-slot per doc
/// because the only realistic divergence is `Options{}` (the inlay/lens/
/// M0500 path) vs. `Options{ .mangle_external_bindings = true }` (the
/// `runShowMinifiedOutput` cold path), which already manages its own
/// scratch arena and does not call this helper.
pub fn getMinifyEstimate(
    self: *Handler,
    uri: []const u8,
    options: MinifyEstimator.Options,
) MinifyEstimateError!*const MinifyEstimator.EstimateResult {
    const doc = self.documents.getPtr(uri) orelse return error.DocumentNotFound;

    // Run / reuse analysis so the cache key (`module_version`) and the
    // module pointer come from the same source of truth.
    const analysis = self.analyzeDocument(uri) catch return error.NoModule;
    const module = analysis.module orelse return error.NoModule;

    const version: u32 = if (doc.parse) |*p| p.module_version else 0;

    if (doc.minify_cache) |*hot| {
        if (hot.module_version == version and optionsEql(hot.options, options)) {
            return &hot.result;
        }
        hot.deinit();
        doc.minify_cache = null;
    }

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer arena.deinit();
    const result = MinifyEstimator.estimate(arena.allocator(), @constCast(module), options) catch
        return error.OutOfMemory;

    doc.minify_cache = .{
        .arena = arena,
        .module_version = version,
        .options = options,
        .result = result,
    };
    return &doc.minify_cache.?.result;
}

/// Field-by-field equality for `MinifyEstimator.Options`. Spelling it out
/// future-proofs the cache-hit predicate against anyone adding a
/// non-trivially-comparable field (e.g. a slice).
fn optionsEql(a: MinifyEstimator.Options, b: MinifyEstimator.Options) bool {
    return a.mangle_external_bindings == b.mangle_external_bindings and
        a.sort_declarations == b.sort_declarations and
        a.scope_local_rename == b.scope_local_rename and
        a.tree_shaking == b.tree_shaking and
        a.use_full_minify == b.use_full_minify;
}

/// Translate the document's resolved minify settings into the
/// `MinifyEstimator.Options` the cache + estimator pass-through every
/// hot-path site (inlay hints, code lens, M-rules, refresh) uses.
/// Centralised so flipping a Phase-8 setting propagates everywhere
/// without each call site reaching back into `effectiveMinifyFor`.
pub fn estimatorOptionsFor(self: *const Handler, uri: []const u8) MinifyEstimator.Options {
    const eff = self.effectiveMinifyFor(uri);
    return .{
        .use_full_minify = eff.use_full_minify,
    };
}

/// Public refresh entry point. Phase 7 native debounce + WASM
/// `wgslender/recomputeMinifyInsights` notification both call this to
/// warm the cache for the document's currently-resolved minify state.
/// No-op when the doc is unknown, the parse failed, or
/// `effectiveMinifyFor(uri)` resolves to a state that needs no estimator
/// work (mode = off with no insights/lints active) — that's how the
/// "no recomputation when mode=off regardless of edits" test stays
/// honest.
pub fn refreshMinifyInsights(self: *Handler, uri: []const u8) void {
    if (!self.documents.contains(uri)) return;
    const eff = self.effectiveMinifyFor(uri);
    if (!eff.insightsActive() and !eff.lintsActive()) return;
    _ = self.getMinifyEstimate(uri, self.estimatorOptionsFor(uri)) catch return;
}

// =========================================================================
// Diagnostics — see lsp/handler/diagnostics.zig
// =========================================================================

pub const Diagnostics = @import("handler/diagnostics.zig");
pub const validateDocument = Diagnostics.validateDocument;
pub const validateDocumentFull = Diagnostics.validateDocumentFull;
pub const validateDocumentCheap = Diagnostics.validateDocumentCheap;
pub const freeDiagnostics = Diagnostics.freeDiagnostics;
pub const convertDiagnostic = Diagnostics.convertDiagnostic;

// =========================================================================
// Code Actions — see lsp/handler/code_actions.zig
// =========================================================================

pub const CodeActions = @import("handler/code_actions.zig");
pub const VertexReturnTarget = CodeActions.VertexReturnTarget;
pub const computeCodeActions = CodeActions.computeCodeActions;
pub const freeCodeActions = CodeActions.freeCodeActions;
pub const extractDidYouMean = CodeActions.extractDidYouMean;
pub const extractTypeMismatch = CodeActions.extractTypeMismatch;
pub const isSafeCastTarget = CodeActions.isSafeCastTarget;
pub const extractDuplicateLocation = CodeActions.extractDuplicateLocation;

// =========================================================================
// Position / Offset Conversion
// =========================================================================

/// Convert an LSP 0-based line:character position to a byte offset in source.
/// `pos.character` is interpreted as a count of UTF-16 code units (the LSP
/// default and what we advertise in `capabilities_json`). Handles LF, CR,
/// and CRLF line endings. Returns `null` on any out-of-domain input: line
/// past EOF, character past EOL (we deliberately do not clamp to line
/// length — callers `orelse return null` and treat malformed positions as
/// drop-the-request, matching `offsetToLspPosition`'s mid-UTF-8
/// rejection), character past EOF on the last line, or a position that
/// lands mid-UTF-8-sequence. A `pos.character` that lands inside a UTF-16
/// surrogate pair (the back half of a 4-byte UTF-8 sequence) snaps to the
/// boundary before the pair — the LSP spec is silent on mid-pair positions
/// and most servers do the same.
pub fn lspPositionToOffset(source: []const u8, pos: Position) ?usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < source.len) {
        if (source[i] == '\r') {
            line += 1;
            if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
        } else if (source[i] == '\n') {
            line += 1;
        }
        i += 1;
    }
    if (line != pos.line) return null;

    var col: u32 = 0;
    var snapped = false;
    while (col < pos.character and i < source.len) {
        if (source[i] == '\r' or source[i] == '\n') return null;
        const seq_len = std.unicode.utf8ByteSequenceLength(source[i]) catch return null;
        if (i + seq_len > source.len) return null;
        const units: u32 = if (seq_len == 4) 2 else 1;
        if (col + units > pos.character) {
            // pos.character lands mid-surrogate-pair — snap to the
            // boundary before the pair. LSP spec is silent on mid-pair
            // positions; this matches what most servers do.
            snapped = true;
            break;
        }
        col += units;
        i += seq_len;
    }
    if (col != pos.character and !snapped) return null;
    return i;
}

/// Convert a byte offset to an LSP 0-based Position. Columns are emitted
/// in UTF-16 code units to match the encoding advertised in
/// `capabilities_json`. Uses a simple linear scan (suitable for typical
/// shader sizes). Returns `null` if `offset` is past end-of-source or
/// lands mid-UTF-8-sequence.
pub fn offsetToLspPosition(source: []const u8, offset: u32) ?Position {
    if (offset > source.len) return null;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < offset) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (c == '\r') {
            line += 1;
            col = 0;
            i += 1;
            if (i < offset and i < source.len and source[i] == '\n') i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch return null;
        if (i + seq_len > source.len) return null;
        if (i + seq_len > offset) return null;
        col += if (seq_len == 4) 2 else 1;
        i += @intCast(seq_len);
    }
    return .{ .line = line, .character = col };
}

/// Convert a byte offset range to an LSP Range.
pub fn offsetRangeToLspRange(source: []const u8, start: u32, end: u32) ?Range {
    const start_pos = offsetToLspPosition(source, start) orelse return null;
    const end_pos = offsetToLspPosition(source, end) orelse return null;
    return .{ .start = start_pos, .end = end_pos };
}

// =========================================================================
// AST Node-at-Position Lookup — see lsp/handler/node_at_offset.zig
// =========================================================================

pub const NodeAtOffset = @import("handler/node_at_offset.zig");
pub const NodeAtPosition = NodeAtOffset.NodeAtPosition;
const findNodeAtOffset = NodeAtOffset.find;

// =========================================================================
// LSP Feature: Hover — see lsp/handler/hover.zig
// =========================================================================

pub const Hover = @import("handler/hover.zig");
pub const HoverResult = Hover.HoverResult;
pub const DocumentHighlight = Hover.DocumentHighlight;
pub const HighlightKind = Hover.HighlightKind;
pub const computeHover = Hover.computeHover;

// =========================================================================
// LSP Feature: Go-to-Definition + Go-to-Type-Definition — see lsp/handler/definition.zig
// =========================================================================

pub const Definition = @import("handler/definition.zig");
pub const computeDefinition = Definition.computeDefinition;
pub const computeTypeDefinition = Definition.computeTypeDefinition;

// =========================================================================
// LSP Feature: References, Document Highlight, Rename — see lsp/handler/references_rename.zig
// =========================================================================

pub const ReferencesRename = @import("handler/references_rename.zig");
pub const computeReferences = ReferencesRename.computeReferences;
pub const computeDocumentHighlight = ReferencesRename.computeDocumentHighlight;
pub const prepareRename = ReferencesRename.prepareRename;
pub const computeRename = ReferencesRename.computeRename;
pub const isValidWgslIdentifier = ReferencesRename.isValidWgslIdentifier;

// =========================================================================
// LSP Feature: Completion — see lsp/handler/completion.zig
// =========================================================================

pub const Completion = @import("handler/completion.zig");
pub const CompletionItem = Completion.CompletionItem;
pub const CompletionKind = Completion.CompletionKind;
pub const computeCompletion = Completion.computeCompletion;


// =========================================================================
// LSP Feature: Signature Help — see lsp/handler/signature_help.zig
// =========================================================================

pub const SignatureHelp = @import("handler/signature_help.zig");
pub const SignatureInfo = SignatureHelp.SignatureInfo;
pub const computeSignatureHelp = SignatureHelp.computeSignatureHelp;

// =========================================================================
// LSP Feature: Document Symbols — see lsp/handler/document_symbols.zig
// =========================================================================

pub const DocumentSymbols = @import("handler/document_symbols.zig");
pub const DocumentSymbolInfo = DocumentSymbols.DocumentSymbolInfo;
pub const SymbolKind = DocumentSymbols.SymbolKind;
pub const computeDocumentSymbols = DocumentSymbols.computeDocumentSymbols;

// =========================================================================
// LSP Feature: Folding Ranges — see lsp/handler/folding_ranges.zig
// =========================================================================

pub const FoldingRanges = @import("handler/folding_ranges.zig");
pub const FoldingRangeInfo = FoldingRanges.FoldingRangeInfo;
pub const computeFoldingRanges = FoldingRanges.computeFoldingRanges;

// =========================================================================
// LSP Feature: Selection Range — see lsp/handler/selection_range.zig
// =========================================================================

pub const SelectionRange = @import("handler/selection_range.zig");
pub const SelectionRangeInfo = SelectionRange.SelectionRangeInfo;
pub const computeSelectionRange = SelectionRange.computeSelectionRange;

// =========================================================================
// LSP Feature: Inlay Hints — see lsp/handler/inlay_hints.zig
// =========================================================================

pub const InlayHints = @import("handler/inlay_hints.zig");
pub const InlayHintInfo = InlayHints.InlayHintInfo;
pub const computeInlayHints = InlayHints.computeInlayHints;
pub const formatMinifyLabel = InlayHints.formatMinifyLabel;

// =========================================================================
// LSP Feature: Unused Symbol Warnings — see lsp/handler/unused_warnings.zig
// =========================================================================

pub const UnusedWarnings = @import("handler/unused_warnings.zig");
pub const appendUnusedWarnings = UnusedWarnings.appendUnusedWarnings;
pub const appendDeadCodeWarnings = UnusedWarnings.appendDeadCodeWarnings;
pub const appendUnusedBindingWarnings = UnusedWarnings.appendUnusedBindingWarnings;

// =========================================================================
// LSP Feature: Code Lens (reference counts) — see lsp/handler/code_lens.zig
// =========================================================================

pub const CodeLens = @import("handler/code_lens.zig");
pub const CodeLensInfo = CodeLens.CodeLensInfo;
pub const computeCodeLens = CodeLens.computeCodeLens;
pub const freeCodeLens = CodeLens.freeCodeLens;
pub const resolveConstExpr = CodeLens.resolveConstExpr;

// =========================================================================
// LSP Feature: Incremental Text Sync — see lsp/handler/incremental_sync.zig
// =========================================================================

pub const IncrementalSync = @import("handler/incremental_sync.zig");
pub const changeDocumentIncremental = IncrementalSync.changeDocumentIncremental;

// =========================================================================
// LSP Feature: Formatting — see lsp/handler/formatting.zig
// =========================================================================

pub const Formatting = @import("handler/formatting.zig");
pub const computeFormatting = Formatting.computeFormatting;

// =========================================================================
// LSP Feature: Semantic Tokens — see lsp/handler/semantic_tokens.zig
// =========================================================================

pub const SemanticTokens = @import("handler/semantic_tokens.zig");
pub const semantic_token_types = SemanticTokens.semantic_token_types;
pub const semantic_token_modifiers = SemanticTokens.semantic_token_modifiers;
pub const computeSemanticTokens = SemanticTokens.computeSemanticTokens;

// =========================================================================
// LSP Feature: Call Hierarchy — see lsp/handler/call_hierarchy.zig
// =========================================================================

pub const CallHierarchy = @import("handler/call_hierarchy.zig");
pub const CallHierarchyItem = CallHierarchy.CallHierarchyItem;
pub const IncomingCall = CallHierarchy.IncomingCall;
pub const OutgoingCall = CallHierarchy.OutgoingCall;
pub const prepareCallHierarchy = CallHierarchy.prepareCallHierarchy;
pub const computeIncomingCalls = CallHierarchy.computeIncomingCalls;
pub const computeOutgoingCalls = CallHierarchy.computeOutgoingCalls;

// =========================================================================
// Tests
// =========================================================================

test "analyzeDocument caches result" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    const a1 = try handler.analyzeDocument("test://file.wgsl");
    const a2 = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(a1 == a2); // same pointer
}

test "changeDocument invalidates analysis cache" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    _ = try handler.analyzeDocument("test://file.wgsl");
    const doc1 = handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc1.analysis != null);
    try handler.changeDocument("test://file.wgsl", "fn g() {}");
    const doc2 = handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis == null);
}

test "analyzeDocument after change re-analyzes" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    const a1 = try handler.analyzeDocument("test://file.wgsl");
    try handler.changeDocument("test://file.wgsl", "fn g() {}");
    const a2 = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(a1 != a2); // different pointer after re-analysis
}

test "analyzeDocument returns semantic data" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "struct S { x: f32, y: f32 }", 1);
    const analysis = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(analysis.module != null);
    const module = analysis.module.?;
    // Should have at least the struct declaration symbol
    try std.testing.expect(module.symbols.items.len > 0);
}



test "offsetToLspPosition: basic" {
    const source = "line1\nline2\nline3";
    // offset 0 → line 0, char 0
    const p0 = offsetToLspPosition(source, 0).?;
    try std.testing.expectEqual(@as(u32, 0), p0.line);
    try std.testing.expectEqual(@as(u32, 0), p0.character);
    // offset 6 → line 1, char 0 (first char of "line2")
    const p6 = offsetToLspPosition(source, 6).?;
    try std.testing.expectEqual(@as(u32, 1), p6.line);
    try std.testing.expectEqual(@as(u32, 0), p6.character);
    // offset 8 → line 1, char 2 (third char of "line2")
    const p8 = offsetToLspPosition(source, 8).?;
    try std.testing.expectEqual(@as(u32, 1), p8.line);
    try std.testing.expectEqual(@as(u32, 2), p8.character);
}

test "offsetToLspPosition: past end returns null" {
    const source = "abc";
    try std.testing.expect(offsetToLspPosition(source, 4) == null);
}

test "offsetToLspPosition: round-trip with lspPositionToOffset" {
    const source = "fn main() {\n  let x = 1;\n  return;\n}";
    // Test a few offsets
    for ([_]u32{ 0, 5, 12, 14, 25, 35 }) |offset| {
        if (offset > source.len) continue;
        const pos = offsetToLspPosition(source, offset) orelse continue;
        const back = lspPositionToOffset(source, pos) orelse continue;
        try std.testing.expectEqual(@as(usize, offset), back);
    }
}

test "offsetRangeToLspRange: basic" {
    const source = "fn main() {\n  let x = 1;\n}";
    const range = offsetRangeToLspRange(source, 3, 7).?;
    // "main" starts at offset 3 on line 0
    try std.testing.expectEqual(@as(u32, 0), range.start.line);
    try std.testing.expectEqual(@as(u32, 3), range.start.character);
    try std.testing.expectEqual(@as(u32, 0), range.end.line);
    try std.testing.expectEqual(@as(u32, 7), range.end.character);
}

test "lspPositionToOffset: basic" {
    const source = "line1\nline2\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 6 (after "line1\n")
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 2, char 2 → offset 14
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 2 }).?);
}

test "lspPositionToOffset: past end" {
    const source = "ab";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 5, .character = 0 }) == null);
}

// =========================================================================
// Additional Edge Case Tests
// =========================================================================

test "lspPositionToOffset: CRLF line endings" {
    const source = "line1\r\nline2\r\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 7 (after "line1\r\n")
    try std.testing.expectEqual(@as(usize, 7), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 1, char 2 → offset 9
    try std.testing.expectEqual(@as(usize, 9), lspPositionToOffset(source, .{ .line = 1, .character = 2 }).?);
    // Line 2, char 0 → offset 14 (after "line1\r\nline2\r\n")
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: CR-only line endings" {
    const source = "line1\rline2\rline3";
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    try std.testing.expectEqual(@as(usize, 12), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: empty source" {
    try std.testing.expectEqual(@as(usize, 0), lspPositionToOffset("", .{ .line = 0, .character = 0 }).?);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 0, .character = 1 }) == null);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 1, .character = 0 }) == null);
}

test "lspPositionToOffset: position at exact end" {
    const source = "abc";
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // One past end returns null
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 4 }) == null);
}

test "lspPositionToOffset: character beyond line length" {
    const source = "short\nab";
    // character 100 on a 5-char line
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 100 }) == null);
}

// =========================================================================
// UTF-16 Code-Unit Tests
// =========================================================================
//
// We advertise `positionEncoding: utf-16`, so `pos.character` is a count
// of UTF-16 code units. UTF-8 → UTF-16 unit map: 1/2/3-byte sequences
// produce 1 unit; 4-byte sequences produce 2 (a surrogate pair).

test "lspPositionToOffset: 2-byte UTF-8 (Latin Extended)" {
    // "fn ä() {}" — 'ä' is 0xC3 0xA4 (2 bytes, 1 UTF-16 unit).
    const source = "fn ä() {}";
    // char 0..2 are ASCII "fn ", same byte and unit count.
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // char 4 lands after the 2-byte 'ä' → byte offset 5.
    try std.testing.expectEqual(@as(usize, 5), lspPositionToOffset(source, .{ .line = 0, .character = 4 }).?);
    // char 5 lands on '(' at byte 6.
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 0, .character = 5 }).?);
}

test "lspPositionToOffset: 3-byte UTF-8 (CJK ideograph)" {
    // "const 中: i32 = 1;" — '中' is 0xE4 0xB8 0xAD (3 bytes, 1 UTF-16 unit).
    const source = "const 中: i32 = 1;";
    // After "const " (6 ASCII bytes / 6 units).
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 0, .character = 6 }).?);
    // After '中' — 1 unit, 3 bytes → byte 9.
    try std.testing.expectEqual(@as(usize, 9), lspPositionToOffset(source, .{ .line = 0, .character = 7 }).?);
    // ':' at byte 9, then ' ' at byte 10. char 8 → byte 10.
    try std.testing.expectEqual(@as(usize, 10), lspPositionToOffset(source, .{ .line = 0, .character = 8 }).?);
}

test "lspPositionToOffset: 4-byte UTF-8 surrogate pair (emoji)" {
    // "// 🎉\nfn f(){}" — 🎉 is 0xF0 0x9F 0x8E 0x89 (4 bytes, 2 UTF-16 units).
    const source = "// \xF0\x9F\x8E\x89\nfn f(){}";
    // char 3 (just before emoji) → byte 3.
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // char 5 (after the surrogate pair) → byte 7 (3 ASCII + 4 UTF-8).
    try std.testing.expectEqual(@as(usize, 7), lspPositionToOffset(source, .{ .line = 0, .character = 5 }).?);
    // char 4 lands mid-surrogate-pair → snap to boundary before emoji
    // (deterministic; matches what most servers do).
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 4 }).?);
    // Line 1, char 0 → after "\n" at byte 8.
    try std.testing.expectEqual(@as(usize, 8), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
}

test "lspPositionToOffset: character past EOL with multi-byte chars" {
    // Line 0 has 1 'visible' character (the emoji = 2 UTF-16 units), no more.
    const source = "\xF0\x9F\x8E\x89\nrest";
    // char 2 (end of emoji) is OK → byte 4.
    try std.testing.expectEqual(@as(usize, 4), lspPositionToOffset(source, .{ .line = 0, .character = 2 }).?);
    // char 3 (one past) returns null — the next byte is '\n'.
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 3 }) == null);
}

// =========================================================================
// Past-EOL Rejection Contract — audit B coverage
// =========================================================================
//
// Pin every line-ending × line-position × multi-byte combination so a
// future edit can't silently re-broaden the input domain to LSP-spec
// clamping. The pre-f04612d helper computed `offset = i + pos.character`
// after walking line breaks and returned a wrong-but-non-null offset for
// past-EOL — this block locks that bug out.

test "lspPositionToOffset: past-EOL regression — pre-f04612d byte-add bug" {
    // The pre-fix helper would have returned 5 (the 's' in "rest") for
    // line=0, char=5. Post-fix must reject — character past EOL must NOT
    // walk into the next line.
    const source = "ab\nrest";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 5 }) == null);
}

test "lspPositionToOffset: past-EOL on first line, LF" {
    const source = "ab\ncd\nef";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on middle line, LF" {
    const source = "ab\ncd\nef";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 1, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on last line, no trailing newline" {
    const source = "ab\ncd\nef";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 2, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on first line, CRLF" {
    const source = "ab\r\ncd\r\nef";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on middle line, CRLF" {
    const source = "ab\r\ncd\r\nef";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 1, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on first line, CR-only" {
    const source = "ab\rcd\ref";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on middle line, CR-only" {
    const source = "ab\rcd\ref";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 1, .character = 10 }) == null);
}

test "lspPositionToOffset: past-EOL on empty line, LF" {
    const source = "a\n\nb";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 1, .character = 1 }) == null);
}

test "lspPositionToOffset: past-EOL on empty line, CRLF" {
    const source = "a\r\n\r\nb";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 1, .character = 1 }) == null);
}

test "lspPositionToOffset: past-EOL by 1 unit after 4-byte char as last on line" {
    // Line 0 = "ab🎉" = 4 UTF-16 units (a=1, b=1, 🎉=2). char=5 is one past.
    const source = "ab\xF0\x9F\x8E\x89\nrest";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 5 }) == null);
}

test "lspPositionToOffset: past-EOL by 2 units (full surrogate past) after 4-byte last char" {
    const source = "ab\xF0\x9F\x8E\x89\nrest";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 6 }) == null);
}

test "lspPositionToOffset: past-EOL by 100 after 4-byte last char" {
    const source = "ab\xF0\x9F\x8E\x89\nrest";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 100 }) == null);
}

test "lspPositionToOffset: past-EOL by 1 on line ending with 4-byte char + CRLF" {
    // Line 0 = "🎉" = 2 UTF-16 units. char=3 is one past.
    const source = "\xF0\x9F\x8E\x89\r\nrest";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 3 }) == null);
}

test "lspPositionToOffset: char exactly at EOL is OK (negative-space pin)" {
    // Pin the boundary: at-EOL must still resolve. char=3 on "abc\ndef" is the
    // position of the LF byte — past-EOL rejection must not regress to
    // rejecting at-EOL.
    const source = "abc\ndef";
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
}

test "offsetToLspPosition: 2-byte UTF-8 boundary" {
    const source = "fn ä() {}";
    // After "fn " (3 ASCII bytes) → char 3.
    try std.testing.expectEqual(@as(u32, 3), offsetToLspPosition(source, 3).?.character);
    // After 'ä' (2 bytes) → char 4.
    try std.testing.expectEqual(@as(u32, 4), offsetToLspPosition(source, 5).?.character);
    // Mid-sequence (byte 4) → null.
    try std.testing.expect(offsetToLspPosition(source, 4) == null);
}

test "offsetToLspPosition: 3-byte UTF-8 boundary" {
    const source = "const 中: i32 = 1;";
    try std.testing.expectEqual(@as(u32, 6), offsetToLspPosition(source, 6).?.character);
    // After '中' (3 bytes) → char 7.
    try std.testing.expectEqual(@as(u32, 7), offsetToLspPosition(source, 9).?.character);
    // Mid-sequence offsets → null.
    try std.testing.expect(offsetToLspPosition(source, 7) == null);
    try std.testing.expect(offsetToLspPosition(source, 8) == null);
}

test "offsetToLspPosition: 4-byte UTF-8 emits surrogate pair" {
    const source = "// \xF0\x9F\x8E\x89\nfn f(){}";
    // After the emoji (4 bytes) → char 5 (3 ASCII + 2 surrogate units).
    const after = offsetToLspPosition(source, 7).?;
    try std.testing.expectEqual(@as(u32, 0), after.line);
    try std.testing.expectEqual(@as(u32, 5), after.character);
    // Mid-surrogate offsets → null.
    try std.testing.expect(offsetToLspPosition(source, 4) == null);
    try std.testing.expect(offsetToLspPosition(source, 5) == null);
    try std.testing.expect(offsetToLspPosition(source, 6) == null);
    // After the LF → line 1, char 0.
    const next_line = offsetToLspPosition(source, 8).?;
    try std.testing.expectEqual(@as(u32, 1), next_line.line);
    try std.testing.expectEqual(@as(u32, 0), next_line.character);
}

test "offsetToLspPosition / lspPositionToOffset: round-trip across mixed UTF-8 widths" {
    // 1-byte 'a', 2-byte 'ä', 3-byte '中', 4-byte 🎉.
    const source = "a\xC3\xA4 \xE4\xB8\xAD \xF0\x9F\x8E\x89 end";
    // Walk every UTF-8 boundary; identity round-trip at each.
    const boundaries = [_]u32{ 0, 1, 3, 4, 7, 8, 12, 13, 14, 15, 16 };
    for (boundaries) |off| {
        if (off > source.len) continue;
        const pos = offsetToLspPosition(source, off) orelse return error.PositionNull;
        const back = lspPositionToOffset(source, pos) orelse return error.OffsetNull;
        try std.testing.expectEqual(@as(usize, off), back);
    }
}

test "offsetRangeToLspRange: range spans a 4-byte char" {
    // Range covering "// 🎉" → start at 0, end at 7 (after emoji).
    const source = "// \xF0\x9F\x8E\x89\nfn f(){}";
    const range = offsetRangeToLspRange(source, 0, 7).?;
    try std.testing.expectEqual(@as(u32, 0), range.start.line);
    try std.testing.expectEqual(@as(u32, 0), range.start.character);
    try std.testing.expectEqual(@as(u32, 0), range.end.line);
    // 3 ASCII + 2 surrogate units = 5.
    try std.testing.expectEqual(@as(u32, 5), range.end.character);
}


test "convertDiagnostic OOM on message dupe yields empty message" {
    // FailingAllocator that fails on the first allocation (the message dupe).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    const entry = WgslDiagnostic.Entry{ .message = "some error" };
    const result = convertDiagnostic(alloc, "", &entry);

    // OOM fallback: message should be empty, not a dangling borrowed slice.
    try std.testing.expectEqual(@as(usize, 0), result.message.len);

    // freeDiagnostics must not crash — the empty message is skipped by the len > 0 guard.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}

test "convertDiagnostic OOM on related message dupe yields empty message" {
    // Allocator that succeeds for the related[] alloc but fails on the string dupe.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    const related = [_]WgslDiagnostic.RelatedInfo{
        .{ .message = "related note" },
    };
    const entry = WgslDiagnostic.Entry{
        .message = "main error",
        .related = &related,
    };
    const result = convertDiagnostic(alloc, "", &entry);

    // The related array was allocated (alloc #0), but the dupe (#1) failed.
    if (result.related.len > 0) {
        try std.testing.expectEqual(@as(usize, 0), result.related[0].message.len);
    }

    // Clean up: freeDiagnostics must handle this without crashing.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}

test "convertDiagnostic with message and related round-trips through freeDiagnostics" {
    const related = [_]WgslDiagnostic.RelatedInfo{
        .{ .message = "see declaration here" },
        .{ .message = "first used here" },
    };
    const entry = WgslDiagnostic.Entry{
        .message = "duplicate definition",
        .code = "E0100",
        .related = &related,
    };
    const result = convertDiagnostic(std.testing.allocator, "", &entry);

    // Verify all strings were duped (owned, not borrowed).
    try std.testing.expectEqualStrings("duplicate definition", result.message);
    try std.testing.expectEqual(@as(usize, 2), result.related.len);
    try std.testing.expectEqualStrings("see declaration here", result.related[0].message);
    try std.testing.expectEqualStrings("first used here", result.related[1].message);

    // freeDiagnostics must free all owned memory without leaking.
    // std.testing.allocator detects leaks.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}
