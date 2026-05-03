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
settings: Settings = .{},
/// Client-provided minifier-mode layer (from `workspace/configuration` or
/// `workspace/didChangeConfiguration`). Merged with the project-config
/// layer and the per-document magic-comment layer in `effectiveMinify()`.
workspace_minify: MinifySettings.Partial = .{},
/// Project-config layer — seeded from `wgslender.json` via `Config.discover`
/// before the first settings pull. Empty until the LSP entry point wires it.
project_minify: MinifySettings.Partial = .{},
/// Per-rule severity overrides keyed by diagnostic **code** (e.g. `"M0100"`)
/// — the JSON shape from `minifyLints.severities` in the client's
/// configuration payload. Translated into `Linter.Options.RuleOverride[]`
/// at validate-time via `Linter.registry.byCode`. Lifetime is workspace-
/// scoped: re-populated whenever `applyClientSettings` sees a fresh
/// `severities` object, freed on `Handler.deinit`. Keys are dup'd into
/// `gpa` because the parsed JSON they came from is freed by the caller
/// after `applyClientSettings` returns.
workspace_minify_severities: std.StringHashMapUnmanaged(WgslDiagnostic.Severity) = .empty,

/// Client-provided LSP settings. Pulled from the client via
/// `workspace/configuration` (section `"wgslender"`) or seeded from
/// `InitializeParams.initializationOptions`. Defaults leave every feature on.
pub const Settings = struct {
    inlay_hints_enabled: bool = true,
    diagnostics_enabled: bool = true,
};

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

    self.clearMinifySeverities();
    self.workspace_minify_severities.deinit(self.gpa);
}

/// Free every key in `workspace_minify_severities` and clear the map.
/// Used both by the workspace settings refresh path (when the user
/// supplies a new severities object) and by `deinit`.
fn clearMinifySeverities(self: *Handler) void {
    var sit = self.workspace_minify_severities.iterator();
    while (sit.next()) |kv| self.gpa.free(kv.key_ptr.*);
    self.workspace_minify_severities.clearRetainingCapacity();
}

fn invalidateAnalysis(self: *Handler, uri: []const u8) void {
    const doc = self.documents.getPtr(uri) orelse return;
    self.invalidateAnalysisAt(doc);
}

fn invalidateAnalysisAt(self: *Handler, doc: *Document) void {
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
fn rebuildParse(self: *Handler, doc: *Document) void {
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
fn rebuildMagic(self: *Handler, doc: *Document) void {
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

/// Merge a client-provided settings object into `self.settings`. Fields that
/// are missing or of the wrong type are silently ignored — matching the
/// permissive behavior of `Config.parseJson` for project config files.
///
/// Schema:
///   {
///     "inlayHints":             { "enabled": bool },
///     "diagnostics":            { "enabled": bool },
///     "minifyMode":             "off" | "insights" | "strict",
///     "minifyInsights":         { "format": "delta"|"bytes"|"both",
///                                 "functionSize": bool, "declSize": bool, "totalSize": bool },
///     "minifyLints":            { "enabled": bool, "budgetBytes": int?, "severities": { code: severity } },
///     "minifyEstimator":        { "useFullMinify": bool },
///     "mangleExternalBindings": bool
///   }
pub fn applyClientSettings(self: *Handler, value: std.json.Value) void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
    // Any settings refresh can shift `effectiveMinifyFor` (mode toggle,
    // mangle flag, severities map) — over-invalidating once per
    // configuration pull is far cheaper than a per-field dirty check
    // and matches the once-per-user-action cadence of this entry point.
    self.invalidateAllMinifyCaches();
    if (obj.get("inlayHints")) |ih| switch (ih) {
        .object => |o| if (o.get("enabled")) |b| switch (b) {
            .bool => |v| self.settings.inlay_hints_enabled = v,
            else => {},
        },
        else => {},
    };
    if (obj.get("diagnostics")) |d| switch (d) {
        .object => |o| if (o.get("enabled")) |b| switch (b) {
            .bool => |v| self.settings.diagnostics_enabled = v,
            else => {},
        },
        else => {},
    };
    if (obj.get("minifyMode")) |v| switch (v) {
        .string => |s| if (MinifySettings.Mode.fromString(s)) |m| {
            self.workspace_minify.mode = m;
        },
        else => {},
    };
    if (obj.get("minifyInsights")) |v| switch (v) {
        .object => |o| {
            if (o.get("format")) |f| switch (f) {
                .string => |s| if (MinifySettings.InsightsFormat.fromString(s)) |fmt| {
                    self.workspace_minify.format = fmt;
                },
                else => {},
            };
            if (o.get("functionSize")) |b| switch (b) {
                .bool => |x| self.workspace_minify.function_size = x,
                else => {},
            };
            if (o.get("declSize")) |b| switch (b) {
                .bool => |x| self.workspace_minify.decl_size = x,
                else => {},
            };
            if (o.get("totalSize")) |b| switch (b) {
                .bool => |x| self.workspace_minify.total_size = x,
                else => {},
            };
        },
        else => {},
    };
    if (obj.get("minifyLints")) |v| switch (v) {
        .object => |o| {
            if (o.get("enabled")) |b| switch (b) {
                .bool => |x| self.workspace_minify.lints_enabled = x,
                else => {},
            };
            if (o.get("severities")) |sv| switch (sv) {
                .object => |sm| self.applyMinifySeverities(sm) catch |err| switch (err) {
                    // OOM during settings parse: leave previous map intact
                    // rather than half-applying a partial set. Mirrors the
                    // permissive behaviour for malformed individual entries.
                    error.OutOfMemory => {},
                },
                else => {},
            };
            // `budgetBytes` (M0500 size budget). Negative values and
            // non-integers are silently ignored — same permissive shape
            // as the rest of this parser. `null`/missing leaves the
            // previous value in place; clients reset by sending an
            // explicit `null` or by re-issuing the whole settings block
            // without the key (workspace replays clear all fields).
            if (o.get("budgetBytes")) |bv| switch (bv) {
                .integer => |i| {
                    self.workspace_minify.budget_bytes = if (i >= 0) @intCast(i) else null;
                },
                .null => self.workspace_minify.budget_bytes = null,
                else => {},
            };
        },
        else => {},
    };
    if (obj.get("mangleExternalBindings")) |v| switch (v) {
        .bool => |x| self.workspace_minify.mangle_external_bindings = x,
        else => {},
    };
    // `wgslender.minifyEstimator.useFullMinify` (Phase 8): flips the
    // estimator from the cheap length-only pass to the production
    // MinifyRenamer + gzip-of-output pass for ground-truth byte/gz
    // counts. Wrong type is silently ignored, matching the rest of
    // this parser.
    if (obj.get("minifyEstimator")) |v| switch (v) {
        .object => |o| {
            if (o.get("useFullMinify")) |b| switch (b) {
                .bool => |x| self.workspace_minify.use_full_minify = x,
                else => {},
            };
        },
        else => {},
    };
}

/// Replace the workspace-scoped severity map with the contents of a
/// fresh `severities` object from `minifyLints`. Keys are dup'd because
/// the source JSON is freed by the caller. Invalid severity strings and
/// non-string values are silently skipped, matching the permissive
/// behaviour of the other settings parsers.
fn applyMinifySeverities(self: *Handler, sm: std.json.ObjectMap) !void {
    self.clearMinifySeverities();
    var it = sm.iterator();
    while (it.next()) |kv| {
        const sev_str = switch (kv.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        const sev = parseMinifySeverity(sev_str) orelse continue;
        const key_dup = try self.gpa.dupe(u8, kv.key_ptr.*);
        errdefer self.gpa.free(key_dup);
        try self.workspace_minify_severities.put(self.gpa, key_dup, sev);
    }
}

/// String → Diagnostic.Severity mapping for the `severities` JSON map.
/// Accepts `off` (= disabled), `hint`, `info`, `warn` / `warning`, and
/// `error`. Returns null for anything else so the caller can drop the
/// entry.
fn parseMinifySeverity(s: []const u8) ?WgslDiagnostic.Severity {
    if (std.mem.eql(u8, s, "off")) return .disabled;
    if (std.mem.eql(u8, s, "hint")) return .hint;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    return null;
}

/// Resolve the effective minifier-mode state for callers without a
/// document context (e.g. command handlers that act on the whole server).
/// The magic-comment layer is empty here — feature paths that operate on
/// a specific document must use `effectiveMinifyFor(uri)` instead.
pub fn effectiveMinify(self: *const Handler) MinifySettings.Effective {
    return MinifySettings.resolve(self.project_minify, self.workspace_minify, .{});
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
    return MinifySettings.resolve(self.project_minify, self.workspace_minify, magic);
}

// =========================================================================
// workspace/executeCommand
// =========================================================================

pub const CommandError = error{
    UnknownCommand,
    InvalidParams,
    DocumentNotFound,
    OutOfMemory,
    MinifyFailed,
    ReflectFailed,
};

/// Result of running `wgslender.showMinifiedOutput`. Mirrors master-plan
/// §9.2: the client opens a virtual document with `minified_text` and
/// uses the byte counts for status-bar / lens display without
/// re-deriving them. All four fields are owned by the request arena
/// passed into `runShowMinifiedOutput`; the caller serialises them and
/// the arena's `deinit` releases everything.
pub const MinifyCommandResult = struct {
    uri: []const u8,
    minified_text: []const u8,
    byte_count: u32,
    gz_count: u32,
};

/// Result of `wgslender/reflect` (custom LSP request). The shared handler
/// reflects the analyzed module and serialises the JSON itself so neither
/// transport (native NativeServer / WASM lsp) needs to know the schema.
/// All slices are owned by the request arena passed to `runReflect`.
pub const ReflectCommandResult = struct {
    uri: []const u8,
    /// Compact JSON output (use `prettyPrint = true` to format).
    json: []const u8,
    version: wgslender.Reflect.JsonVersion,
};

/// Dispatch a `workspace/executeCommand` request. `args` matches the LSP
/// `ExecuteCommandParams.arguments` shape: `null` when the client sent no
/// arguments, otherwise a slice of `LSPAny` (= `std.json.Value`).
///
/// Used for the void-returning commands (mode toggles). Data-returning
/// commands (e.g. `wgslender.showMinifiedOutput`) live on dedicated
/// methods because the wire shape — and the arena lifetime — differs.
pub fn executeCommand(self: *Handler, name: []const u8, args: ?[]const std.json.Value) CommandError!void {
    if (std.mem.eql(u8, name, "wgslender.setMinifyMode")) {
        const items = args orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const s = switch (items[0]) {
            .string => |x| x,
            else => return error.InvalidParams,
        };
        const m = MinifySettings.Mode.fromString(s) orelse return error.InvalidParams;
        self.workspace_minify.mode = m;
        return;
    }
    if (std.mem.eql(u8, name, "wgslender.toggleMinifyMode")) {
        const current = self.effectiveMinify().mode;
        const next: MinifySettings.Mode = switch (current) {
            .off => .insights,
            .insights => .strict,
            .strict => .off,
        };
        self.workspace_minify.mode = next;
        return;
    }
    if (std.mem.eql(u8, name, "wgslender.recomputeMinifyInsights")) {
        // Phase 7 native debounce shim. lsp-kit's `basic_server.run`
        // dispatch only knows method names registered with the
        // generator, so a custom `wgslender/recomputeMinifyInsights`
        // notification can't be routed by the native transport. We
        // expose the same operation as a command instead — clients
        // send `workspace/executeCommand` with `[uri]` as the only
        // argument. The WASM transport keeps the notification name
        // (raw dispatch matches strings directly) and converges on
        // `Handler.refreshMinifyInsights`.
        const items = args orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        self.refreshMinifyInsights(uri);
        return;
    }
    return error.UnknownCommand;
}

/// Run `wgslender.showMinifiedOutput` for `uri`. The full minifier
/// pipeline runs against the document's current source — this is the
/// "cold path" the master plan §2.4 reserves for on-command requests
/// (the lens title itself uses the cheap `MinifyEstimator`). All
/// returned slices are owned by `arena`; the caller's request arena is
/// the right home because the bridge layer serialises the result and
/// tears the arena down right after.
///
/// `byte_count` / `gz_count` come from a parallel `MinifyEstimator`
/// pass so the JSON response carries the same numbers the lens title
/// already showed. Using estimator output here (rather than
/// `result.minified_size`) keeps the lens / response numbers in
/// lockstep — the estimator is the authoritative source for in-LSP
/// size hints.
pub fn runShowMinifiedOutput(
    self: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
) CommandError!MinifyCommandResult {
    const doc = self.documents.getPtr(uri) orelse return error.DocumentNotFound;
    const eff = self.effectiveMinifyFor(uri);

    // Minifier.minify wants sentinel-terminated source.
    const source = try arena.dupeZ(u8, doc.source);

    const result = wgslender.Minifier.minify(arena, source, .{
        .mangle_external_bindings = eff.mangle_external_bindings,
    }) catch return error.MinifyFailed;

    // Estimator runs against the analysis module so byte_count matches
    // what the code lens displayed. It mutates `is_live`, so a scratch
    // arena keeps the side-effects scoped to this call.
    var est_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer est_arena.deinit();

    const analysis = self.analyzeDocument(uri) catch return error.MinifyFailed;
    const module = analysis.module orelse return error.MinifyFailed;

    const est = wgslender.MinifyEstimator.estimate(
        est_arena.allocator(),
        @constCast(module),
        .{ .mangle_external_bindings = eff.mangle_external_bindings },
    ) catch return error.MinifyFailed;

    return .{
        .uri = try arena.dupe(u8, uri),
        .minified_text = result.code,
        .byte_count = est.total_min,
        .gz_count = est.total_gz,
    };
}

/// Reflect the document and serialise the result to JSON at the requested
/// schema version. Reuses the cached analysis module (so a hot doc skips
/// re-tokenize + re-parse) and serialises into the caller's arena.
pub fn runReflect(
    self: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
    version: wgslender.Reflect.JsonVersion,
    pretty: bool,
) CommandError!ReflectCommandResult {
    if (self.documents.getPtr(uri) == null) return error.DocumentNotFound;

    const analysis = self.analyzeDocument(uri) catch return error.ReflectFailed;
    const module = analysis.module orelse return error.ReflectFailed;

    var result = wgslender.Reflect.reflect(arena, @constCast(module)) catch
        return error.ReflectFailed;
    // `reflect()` allocates from `arena`; no internal arena to drain.
    _ = &result;

    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (pretty) {
        result.toJsonPrettyVersion(&json_buf, arena, version) catch return error.OutOfMemory;
    } else {
        result.toJsonVersion(&json_buf, arena, version) catch return error.OutOfMemory;
    }

    return .{
        .uri = try arena.dupe(u8, uri),
        .json = json_buf.items,
        .version = version,
    };
}

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
    for (parse.module.symbols.items) |*sym| {
        sym.flags.is_live = false;
    }
    _ = wgslender.Dce.mark(parse.arena.allocator(), parse.module) catch {};

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
            _ = wgslender.Dce.mark(arena.allocator(), module) catch {};
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
// LSP Feature: Go-to-Definition
// =========================================================================

pub fn computeDefinition(self: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    return symbolToRange(module, source, nodeSymbolIndex(node));
}

fn nodeSymbolIndex(node: NodeAtPosition) Ast.SymbolIndex {
    return switch (node) {
        .ident => |id| id.ref,
        .type_ref => |tr| tr.ref,
        .decl_name => |dn| dn.sym_idx,
        .member_access => |ma| ma.ref,
        .binary_expr, .none => .none,
    };
}

fn symbolToRange(module: *const Ast.Module, source: []const u8, ref: Ast.SymbolIndex) ?Range {
    if (!ref.isValid()) return null;
    const sym = module.symbols.items[ref.index()];
    return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
}

// =========================================================================
// LSP Feature: Find All References
// =========================================================================

const Edits = wgslender.Edits;

pub fn computeReferences(self: *Handler, uri: []const u8, position: Position, include_declaration: bool) !?[]Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    const target: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        .type_ref => |tr| tr.ref,
        else => return null,
    };
    if (!target.isValid()) return null;

    const refs = try Edits.findReferences(self.gpa, module, target, include_declaration);
    defer self.gpa.free(refs);

    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    defer ranges.deinit(self.gpa);
    try ranges.ensureTotalCapacity(self.gpa, refs.len);
    for (refs) |r| {
        if (offsetRangeToLspRange(source, r.start, r.end)) |range| {
            ranges.appendAssumeCapacity(range);
        }
    }
    return try self.gpa.dupe(Range, ranges.items);
}

// =========================================================================
// LSP Feature: Document Highlight
// =========================================================================

pub fn computeDocumentHighlight(self: *Handler, uri: []const u8, position: Position) !?[]DocumentHighlight {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    const target: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        .type_ref => |tr| tr.ref,
        else => return null,
    };
    if (!target.isValid()) return null;

    const refs = try Edits.findReferences(self.gpa, module, target, true);
    defer self.gpa.free(refs);

    var highlights: std.ArrayListUnmanaged(DocumentHighlight) = .empty;
    defer highlights.deinit(self.gpa);
    try highlights.ensureTotalCapacity(self.gpa, refs.len);
    for (refs) |r| {
        if (offsetRangeToLspRange(source, r.start, r.end)) |range| {
            highlights.appendAssumeCapacity(.{
                .range = range,
                .kind = if (r.is_write) .write else .read,
            });
        }
    }
    return try self.gpa.dupe(DocumentHighlight, highlights.items);
}

// =========================================================================
// LSP Feature: Rename Symbol
// =========================================================================

const Lexer = wgslender.Lexer;

pub fn prepareRename(self: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)));
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            const sym = module.symbols.items[tr.ref.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len)));
        },
        else => return null,
    }
}

pub const isValidWgslIdentifier = Edits.isValidWgslIdentifier;

pub fn computeRename(self: *Handler, uri: []const u8, position: Position, new_name: []const u8) !?[]LspTextEdit {
    if (!isValidWgslIdentifier(new_name)) return null;

    const refs = (try self.computeReferences(uri, position, true)) orelse return null;
    defer self.gpa.free(refs);

    if (refs.len == 0) return null;

    const edits = try self.gpa.alloc(LspTextEdit, refs.len);
    for (refs, 0..) |ref_range, i| {
        edits[i] = .{
            .range = ref_range,
            .new_text = new_name,
        };
    }
    return edits;
}

// =========================================================================
// LSP Feature: Completion
// =========================================================================

const Builtins = wgslender.Builtins;

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8 = "",
};

pub const CompletionKind = enum(u8) {
    variable,
    function,
    struct_type,
    field,
    keyword,
    builtin,
    type_name,
    attribute,
};

const wgsl_type_names = [_][]const u8{
    "bool",               "i32",                      "u32",                           "f32",                     "f16",
    "vec2",               "vec3",                     "vec4",                          "vec2i",                   "vec3i",
    "vec4i",              "vec2u",                    "vec3u",                         "vec4u",                   "vec2f",
    "vec3f",              "vec4f",                    "vec2h",                         "vec3h",                   "vec4h",
    "mat2x2",             "mat2x3",                   "mat2x4",                        "mat3x2",                  "mat3x3",
    "mat3x4",             "mat4x2",                   "mat4x3",                        "mat4x4",                  "mat2x2f",
    "mat2x3f",            "mat2x4f",                  "mat3x2f",                       "mat3x3f",                 "mat3x4f",
    "mat4x2f",            "mat4x3f",                  "mat4x4f",                       "mat2x2h",                 "mat2x3h",
    "mat2x4h",            "mat3x2h",                  "mat3x3h",                       "mat3x4h",                 "mat4x2h",
    "mat4x3h",            "mat4x4h",                  "array",                         "atomic",                  "ptr",
    "sampler",            "sampler_comparison",       "texture_1d",                    "texture_2d",              "texture_2d_array",
    "texture_3d",         "texture_cube",             "texture_cube_array",            "texture_multisampled_2d", "texture_storage_1d",
    "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",            "texture_depth_2d",        "texture_depth_2d_array",
    "texture_depth_cube", "texture_depth_cube_array", "texture_depth_multisampled_2d",
};

const wgsl_attributes = [_][]const u8{
    "align",    "binding",     "builtin",   "compute",
    "const",    "diagnostic",  "fragment",  "group",
    "id",       "interpolate", "invariant", "location",
    "must_use", "size",        "vertex",    "workgroup_size",
};

pub fn computeCompletion(self: *Handler, uri: []const u8, position: Position) ![]CompletionItem {
    const doc = self.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return &.{});

    // Check trigger context
    if (offset > 0 and source[offset - 1] == '@') {
        return self.attributeCompletion();
    }

    if (offset > 0 and source[offset - 1] == '.') {
        return self.memberCompletion(uri, source, offset);
    }

    return self.generalCompletion(uri);
}

fn attributeCompletion(self: *Handler) ![]CompletionItem {
    const items = try self.gpa.alloc(CompletionItem, wgsl_attributes.len);
    for (wgsl_attributes, 0..) |attr, i| {
        items[i] = .{ .label = attr, .kind = .attribute };
    }
    return items;
}

fn memberCompletion(self: *Handler, uri: []const u8, source: []const u8, dot_offset: u32) ![]CompletionItem {
    // Find the identifier before the dot
    var start = dot_offset - 1;
    if (start > 0 and source[start] == '.') start -= 1; // skip the dot
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    const base_name = source[start .. dot_offset - 1];
    if (base_name.len == 0) return &.{};

    // Try to resolve the base type via analysis
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};

    // Find the symbol for base_name and its type
    var base_type: ?wgslender.Types.Type = null;
    for (module.symbols.items, 0..) |sym, idx| {
        if (std.mem.eql(u8, sym.original_name, base_name)) {
            base_type = analysis.symbol_types.get(@intCast(idx));
            break;
        }
    }

    if (base_type) |bt| {
        switch (bt) {
            .@"struct" => |st| {
                const items = try self.gpa.alloc(CompletionItem, st.fields.len);
                for (st.fields, 0..) |field, i| {
                    items[i] = .{ .label = field.name, .kind = .field, .detail = field.typ.string() };
                }
                return items;
            },
            .vector => {
                // Vector swizzle components
                const swizzles = [_][]const u8{ "x", "y", "z", "w", "r", "g", "b", "a" };
                const items = try self.gpa.alloc(CompletionItem, swizzles.len);
                for (swizzles, 0..) |s, i| {
                    items[i] = .{ .label = s, .kind = .field };
                }
                return items;
            },
            else => {},
        }
    }

    return &.{};
}

fn generalCompletion(self: *Handler, uri: []const u8) ![]CompletionItem {
    var items: std.ArrayListUnmanaged(CompletionItem) = .empty;
    defer items.deinit(self.gpa);

    // Module-level symbols from analysis
    if (self.analyzeDocument(uri)) |analysis| {
        if (analysis.module) |module| {
            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.original_name.len == 0) continue;
                const kind: CompletionKind = switch (sym.kind) {
                    .function => .function,
                    .@"struct" => .struct_type,
                    .parameter, .let, .@"var" => .variable,
                    .@"const", .override => .variable,
                    else => continue,
                };
                const detail = if (analysis.symbol_types.get(@intCast(idx))) |t| t.string() else "";
                try items.append(self.gpa, .{ .label = sym.original_name, .kind = kind, .detail = detail });
            }
        }
    } else |_| {}

    // Builtin functions
    for (Builtins.names()) |name| {
        try items.append(self.gpa, .{ .label = name, .kind = .builtin });
    }

    // Keywords
    for (Lexer.keywords_map.keys()) |kw| {
        try items.append(self.gpa, .{ .label = kw, .kind = .keyword });
    }

    // Built-in type names
    for (&wgsl_type_names) |tn| {
        try items.append(self.gpa, .{ .label = tn, .kind = .type_name });
    }

    return try self.gpa.dupe(CompletionItem, items.items);
}

// =========================================================================
// LSP Feature: Signature Help
// =========================================================================

pub const SignatureInfo = struct {
    label: []const u8,
    parameters: []const []const u8,
    active_parameter: u32,
};

pub fn computeSignatureHelp(self: *Handler, uri: []const u8, position: Position) !?SignatureInfo {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);

    // Scan backward to find enclosing '(' and the function name before it
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var i: u32 = offset;
    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (c == ')') {
            paren_depth += 1;
        } else if (c == '(') {
            if (paren_depth == 0) break; // found the enclosing '('
            paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    } else {
        return null; // no enclosing '('
    }

    // i now points to '('. Find the function name before it.
    if (i == 0) return null;
    var name_end = i;
    // Skip whitespace between name and '('
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0) return null;
    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(source[name_start - 1]) or source[name_start - 1] == '_')) name_start -= 1;
    const func_name = source[name_start..name_end];
    if (func_name.len == 0) return null;

    // Check if it's a builtin
    if (Builtins.lookup(func_name)) |builtin| {
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}({d}..{d} args)", .{ func_name, builtin.min_args, builtin.max_args }) catch return null;
        return .{
            .label = try self.gpa.dupe(u8, label),
            .parameters = &.{},
            .active_parameter = comma_count,
        };
    }

    // Check if it's a user-defined function
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!std.mem.eql(u8, sym.original_name, func_name)) continue;

                // Build signature label and parameter names
                var buf: [512]u8 = undefined;
                var pos_in_buf: usize = 0;
                const header = std.fmt.bufPrint(&buf, "fn {s}(", .{func_name}) catch return null;
                pos_in_buf = header.len;

                const param_names = try self.gpa.alloc([]const u8, f.parameters.items.len);
                for (f.parameters.items, 0..) |param, pi| {
                    if (pi > 0) {
                        const sep = std.fmt.bufPrint(buf[pos_in_buf..], ", ", .{}) catch return null;
                        pos_in_buf += sep.len;
                    }
                    const p_sym = module.symbols.items[param.name.index()];
                    const p_type = param.typ;
                    const p_str = switch (p_type) {
                        .ident => |t| t.name,
                        .vec => |t| t.shorthand,
                        .mat => |t| t.shorthand,
                        else => "?",
                    };
                    param_names[pi] = p_sym.original_name;
                    const fld = std.fmt.bufPrint(buf[pos_in_buf..], "{s}: {s}", .{ p_sym.original_name, p_str }) catch return null;
                    pos_in_buf += fld.len;
                }

                const tail_str = if (f.return_type) |rt| blk: {
                    const rt_str = switch (rt) {
                        .ident => |t| t.name,
                        .vec => |t| t.shorthand,
                        .mat => |t| t.shorthand,
                        else => "?",
                    };
                    break :blk std.fmt.bufPrint(buf[pos_in_buf..], ") -> {s}", .{rt_str}) catch return null;
                } else std.fmt.bufPrint(buf[pos_in_buf..], ")", .{}) catch return null;
                pos_in_buf += tail_str.len;

                return .{
                    .label = try self.gpa.dupe(u8, buf[0..pos_in_buf]),
                    .parameters = param_names,
                    .active_parameter = comma_count,
                };
            },
            else => {},
        }
    }

    return null;
}

// =========================================================================
// LSP Feature: Document Symbols
// =========================================================================

pub const DocumentSymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
    children: []const DocumentSymbolInfo,
};

pub const SymbolKind = enum(u8) {
    function,
    struct_type,
    variable,
    constant,
    field,
    type_alias,
    override,
};

pub fn computeDocumentSymbols(self: *Handler, uri: []const u8) ![]DocumentSymbolInfo {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var symbols: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
    defer symbols.deinit(self.gpa);

    for (module.declarations.items, 0..) |decl, di| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        const kind: SymbolKind = switch (decl) {
            .function => .function,
            .@"struct" => .struct_type,
            .@"var" => .variable,
            .@"const" => .constant,
            .let => .constant,
            .override => .override,
            .alias => .type_alias,
            .const_assert => continue,
        };

        // Selection range = the name identifier
        const sel_range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;

        // Enclosing range: from this decl's name to next decl's name (or EOF)
        const range_end: u32 = if (di + 1 < module.declarations.items.len) blk: {
            const next_ref = module.declarations.items[di + 1].nameRef();
            if (next_ref.isValid()) break :blk module.symbols.items[next_ref.index()].loc;
            break :blk @as(u32, @intCast(source.len));
        } else @as(u32, @intCast(source.len));
        const range = offsetRangeToLspRange(source, sym.loc, range_end) orelse continue;

        // Children for structs
        var children: []const DocumentSymbolInfo = &.{};
        if (decl == .@"struct") {
            const st = decl.@"struct";
            var ch: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
            for (st.members.items) |member| {
                if (!member.name.isValid()) continue;
                const m_sym = module.symbols.items[member.name.index()];
                const m_sel = offsetRangeToLspRange(source, m_sym.loc, m_sym.loc + @as(u32, @intCast(m_sym.original_name.len))) orelse continue;
                ch.append(self.gpa, .{
                    .name = m_sym.original_name,
                    .kind = .field,
                    .range = m_sel,
                    .selection_range = m_sel,
                    .children = &.{},
                }) catch continue;
            }
            children = ch.toOwnedSlice(self.gpa) catch &.{};
        }

        try symbols.append(self.gpa, .{
            .name = sym.original_name,
            .kind = kind,
            .range = range,
            .selection_range = sel_range,
            .children = children,
        });
    }

    return try self.gpa.dupe(DocumentSymbolInfo, symbols.items);
}

// =========================================================================
// LSP Feature: Folding Ranges
// =========================================================================

pub const FoldingRangeInfo = struct {
    start_line: u32,
    end_line: u32,
    kind: enum { region, comment },
};

pub fn computeFoldingRanges(self: *Handler, uri: []const u8) ![]FoldingRangeInfo {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var ranges: std.ArrayListUnmanaged(FoldingRangeInfo) = .empty;
    defer ranges.deinit(self.gpa);

    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (f.body == null) continue;
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                const start_pos = offsetToLspPosition(source, sym.loc) orelse continue;
                // Find closing brace by scanning source
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(self.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            .@"struct" => |s| {
                if (!s.name.isValid()) continue;
                const sym = module.symbols.items[s.name.index()];
                const start_pos = offsetToLspPosition(source, sym.loc) orelse continue;
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(self.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            else => {},
        }
    }

    return try self.gpa.dupe(FoldingRangeInfo, ranges.items);
}

fn findClosingBrace(source: []const u8, start: u32) ?u32 {
    var depth: i32 = 0;
    var i: u32 = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '{') {
            depth += 1;
        } else if (source[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// =========================================================================
// LSP Feature: Go-to-Type-Definition
// =========================================================================

pub fn computeTypeDefinition(self: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    const sym_idx: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        else => return null,
    };
    if (!sym_idx.isValid()) return null;

    // Get the resolved type of this symbol
    const typ = analysis.symbol_types.get(sym_idx.index()) orelse return null;
    switch (typ) {
        .@"struct" => |st| {
            // Find the struct declaration in module
            for (module.declarations.items) |decl| {
                switch (decl) {
                    .@"struct" => |sd| {
                        if (!sd.name.isValid()) continue;
                        const sym = module.symbols.items[sd.name.index()];
                        if (std.mem.eql(u8, sym.original_name, st.name)) {
                            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    return null;
}

// =========================================================================
// LSP Feature: Inlay Hints
// =========================================================================

pub const InlayHintInfo = struct {
    position: Position,
    label: []const u8,
    kind: enum { type_hint, parameter_hint, const_value_hint, minify_size },
    /// For struct types: the definition range so the hint label is clickable/hoverable.
    def_range: ?Range = null,
    /// Optional human-readable tooltip rendered on hover. Used by minify-size
    /// hints to disclose that the byte count is approximate.
    tooltip: ?[]const u8 = null,
};

pub fn computeInlayHints(self: *Handler, uri: []const u8, range: Range) ![]InlayHintInfo {
    if (!self.settings.inlay_hints_enabled) return &.{};
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;
    // Use the analysis arena for label strings so they share lifetime with type strings
    const label_alloc = if (analysis._arena) |*a| a.allocator() else self.gpa;

    const range_start = lspPositionToOffset(source, range.start) orelse 0;
    const range_end = lspPositionToOffset(source, range.end) orelse source.len;

    var hints: std.ArrayListUnmanaged(InlayHintInfo) = .empty;
    defer hints.deinit(self.gpa);

    for (module.declarations.items) |decl| {
        try self.collectInlayHintsFromDecl(module, analysis, label_alloc, source, decl, range_start, range_end, &hints);
    }

    if (analysis.valid) {
        try self.collectMinifyHints(uri, module, label_alloc, source, &hints);
    }

    return try self.gpa.dupe(InlayHintInfo, hints.items);
}

/// Tooltip attached to every minify-size hint. Discloses that the number is
/// an estimate produced without running a full minify pass.
const minify_hint_tooltip: []const u8 =
    "approximate minified byte size — estimated from the symbol table; " ++
    "the true size may differ slightly until you run a full minify.";

/// Emit byte-size inlay hints when the document's effective minifier-mode is
/// `insights` or `strict`. Hints land at three positions:
///
///   * module-level total at `{0,0}` (gated on `insights.total_size`);
///   * per-function hints at the closing `}` of the function body
///     (gated on `insights.function_size`);
///   * per-non-function-decl hints at the trailing `;` (gated on
///     `insights.decl_size`).
///
/// Labels honour the resolved `insights.format` (`delta`, `bytes`, `both`)
/// and roll over from `B` to `KB` once the formatted value reaches 1024.
fn collectMinifyHints(
    self: *Handler,
    uri: []const u8,
    module: *const wgslender.Ast.Module,
    label_alloc: std.mem.Allocator,
    source: [:0]const u8,
    hints: *std.ArrayListUnmanaged(InlayHintInfo),
) std.mem.Allocator.Error!void {
    const eff = self.effectiveMinifyFor(uri);
    if (!eff.insightsActive()) return;

    // Phase 7: shared per-document cache. The first inlay-hint /
    // code-lens / lint-rule call after a parse-version bump pays the
    // estimator cost; every subsequent call within the same version
    // returns the same pointer. `module` is still consumed below for
    // its declarations list — the cache only replaces the estimator's
    // arena, not the caller's traversal.
    const cached = self.getMinifyEstimate(uri, self.estimatorOptionsFor(uri)) catch return;
    const result = cached;

    if (eff.insights.total_size) {
        const original: u32 = @intCast(source.len);
        const label = formatMinifyLabel(label_alloc, original, result.total_min, eff.insights.format) catch return;
        try hints.append(self.gpa, .{
            .position = .{ .line = 0, .character = 0 },
            .label = label,
            .kind = .minify_size,
            .tooltip = minify_hint_tooltip,
        });
    }

    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;

        const is_function = decl == .function;
        if (is_function and !eff.insights.function_size) continue;
        if (!is_function and !eff.insights.decl_size) continue;

        const estimated: u32 = if (is_function)
            (result.per_function.get(name_ref) orelse continue).min
        else
            (result.per_decl.get(name_ref) orelse continue).min;

        const span = decl.declSpan();
        if (span.end == 0 or span.end > source.len) continue;
        const original = span.end - span.start;
        const pos = offsetToLspPosition(source, span.end) orelse continue;

        const label = formatMinifyLabel(label_alloc, original, estimated, eff.insights.format) catch continue;
        try hints.append(self.gpa, .{
            .position = pos,
            .label = label,
            .kind = .minify_size,
            .tooltip = minify_hint_tooltip,
        });
    }
}

/// Format a single byte-size inlay-hint label. The shape is driven by
/// `format`:
///
///   * `delta`  → `"-NN B"` (savings = original − estimated; never negative
///     in practice, but a `+NN B` shape is used if the estimate is somehow
///     larger than the source);
///   * `bytes`  → `"NN B"` (the post-minify estimate);
///   * `both`   → `"NN B (-NN B)"` (estimate then savings).
///
/// Sub-1024 byte values render as `"NN B"`. Values ≥ 1024 roll over to a
/// one-decimal-place `"X.Y KB"` form.
pub fn formatMinifyLabel(
    arena: std.mem.Allocator,
    original: u32,
    estimated: u32,
    format: MinifySettings.InsightsFormat,
) std.mem.Allocator.Error![]u8 {
    const delta_signed: i64 = @as(i64, original) - @as(i64, estimated);
    const delta_abs: u64 = if (delta_signed < 0) @intCast(-delta_signed) else @intCast(delta_signed);
    const delta_sign: u8 = if (delta_signed < 0) '+' else '-';

    var bytes_buf: [32]u8 = undefined;
    var delta_buf: [32]u8 = undefined;
    const bytes_str = formatSize(&bytes_buf, estimated);
    const delta_str = formatSize(&delta_buf, delta_abs);

    return switch (format) {
        .delta => std.fmt.allocPrint(arena, "{c}{s}", .{ delta_sign, delta_str }),
        .bytes => arena.dupe(u8, bytes_str),
        .both => std.fmt.allocPrint(arena, "{s} ({c}{s})", .{ bytes_str, delta_sign, delta_str }),
    };
}

/// Format `size` as `"NN B"` for sub-1024 values or `"X.Y KB"` for larger
/// ones. Writes into `buf` (≥ 32 bytes is plenty) and returns the slice.
fn formatSize(buf: []u8, size: u64) []u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch unreachable;
    }
    const tenths = (size * 10 + 512) / 1024;
    const whole = tenths / 10;
    const frac = tenths % 10;
    return std.fmt.bufPrint(buf, "{d}.{d} KB", .{ whole, frac }) catch unreachable;
}

fn collectInlayHintsFromDecl(
    self: *Handler,
    module: *const Ast.Module,
    analysis: *const wgslender.Validator.AnalysisResult,
    label_alloc: std.mem.Allocator,
    source: [:0]const u8,
    decl: Ast.Decl,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayListUnmanaged(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (decl) {
        .let => |l| {
            if (l.typ == null) { // No explicit type annotation
                if (l.name.isValid()) {
                    const sym = module.symbols.items[l.name.index()];
                    if (sym.loc >= range_start and sym.loc < range_end) {
                        if (analysis.symbol_types.get(l.name.index())) |typ| {
                            const pos = offsetToLspPosition(source, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse return;
                            try hints.append(self.gpa, .{
                                .position = pos,
                                .label = typ.string(),
                                .kind = .type_hint,
                                .def_range = structDefRange(module, source, typ),
                            });
                        }
                    }
                }
            }
            // Collect array size hints from type annotation
            if (l.typ) |typ| try self.collectArraySizeHints(&analysis.const_values, label_alloc, source, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (l.initializer) |init_expr| try self.collectExprTypeHints(module, &analysis.expr_types, source, init_expr, range_start, range_end, hints, 0);
        },
        .@"var" => |v| {
            // Collect array size hints from type annotation
            if (v.typ) |typ| try self.collectArraySizeHints(&analysis.const_values, label_alloc, source, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (v.initializer) |init_expr| try self.collectExprTypeHints(module, &analysis.expr_types, source, init_expr, range_start, range_end, hints, 0);
        },
        .@"const" => |c| {
            // Collect array size hints from type annotation
            if (c.typ) |typ| try self.collectArraySizeHints(&analysis.const_values, label_alloc, source, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (c.initializer) |init_expr| try self.collectExprTypeHints(module, &analysis.expr_types, source, init_expr, range_start, range_end, hints, 0);
        },
        .function => |f| {
            if (f.body) |body| {
                for (body.stmts.items) |stmt| {
                    try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, stmt, range_start, range_end, hints);
                }
            }
        },
        else => {},
    }
}

fn collectInlayHintsFromStmt(
    self: *Handler,
    module: *const Ast.Module,
    analysis: *const wgslender.Validator.AnalysisResult,
    label_alloc: std.mem.Allocator,
    source: [:0]const u8,
    stmt: Ast.Stmt,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayListUnmanaged(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (stmt) {
        .decl => |d| try self.collectInlayHintsFromDecl(module, analysis, label_alloc, source, d.decl, range_start, range_end, hints),
        .compound => |c| {
            for (c.stmts.items) |s| {
                try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, s, range_start, range_end, hints);
            }
        },
        .@"if" => |i| {
            try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, .{ .compound = i.body }, range_start, range_end, hints);
            if (i.else_branch) |eb| try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, eb, range_start, range_end, hints);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, init_s, range_start, range_end, hints);
            try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, .{ .compound = f.body }, range_start, range_end, hints);
        },
        .@"while" => |w| try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, .{ .compound = w.body }, range_start, range_end, hints),
        .loop => |l| {
            try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, .{ .compound = l.body }, range_start, range_end, hints);
            if (l.continuing) |cont| try self.collectInlayHintsFromStmt(module, analysis, label_alloc, source, .{ .compound = cont }, range_start, range_end, hints);
        },
        .assign => |a| {
            try self.collectExprTypeHints(module, &analysis.expr_types, source, a.right, range_start, range_end, hints, 0);
        },
        .@"return" => |r| {
            if (r.value) |v| try self.collectExprTypeHints(module, &analysis.expr_types, source, v, range_start, range_end, hints, 0);
        },
        .call => |c| {
            try self.collectExprTypeHints(module, &analysis.expr_types, source, .{ .call = c.call }, range_start, range_end, hints, 0);
        },
        else => {},
    }
}

/// Walk a type expression looking for array types with non-literal const size expressions.
/// Emits const_value_hint inlay hints showing the evaluated array size.
/// Labels are allocated from `label_alloc` (typically the analysis arena) so they share
/// the same lifetime as type hint labels and don't need separate freeing.
fn collectArraySizeHints(
    self: *Handler,
    const_values: *const std.AutoHashMapUnmanaged(u32, i64),
    label_alloc: std.mem.Allocator,
    source: [:0]const u8,
    typ: Ast.Type,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayListUnmanaged(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (typ) {
        .array => |arr| {
            if (arr.size) |size_expr| {
                // Only hint when size is not a plain literal (value already visible)
                switch (size_expr) {
                    .literal => {},
                    else => {
                        if (resolveConstExpr(size_expr, const_values)) |val| {
                            const end_offset = exprEndOffset(size_expr);
                            if (end_offset >= range_start and end_offset <= range_end) {
                                const pos = offsetToLspPosition(source, end_offset) orelse return;
                                var buf: [32]u8 = undefined;
                                const label = std.fmt.bufPrint(&buf, " = {d}", .{val}) catch return;
                                try hints.append(self.gpa, .{
                                    .position = pos,
                                    .label = try label_alloc.dupe(u8, label),
                                    .kind = .const_value_hint,
                                });
                            }
                        }
                    },
                }
            }
            // Recurse into element type
            if (arr.elem_type) |et| try self.collectArraySizeHints(const_values, label_alloc, source, et, range_start, range_end, hints);
        },
        .vec => |v| {
            if (v.elem_type) |et| try self.collectArraySizeHints(const_values, label_alloc, source, et, range_start, range_end, hints);
        },
        .mat => |m| {
            if (m.elem_type) |et| try self.collectArraySizeHints(const_values, label_alloc, source, et, range_start, range_end, hints);
        },
        .ptr => |p| try self.collectArraySizeHints(const_values, label_alloc, source, p.elem_type, range_start, range_end, hints),
        .atomic => |a| try self.collectArraySizeHints(const_values, label_alloc, source, a.elem_type, range_start, range_end, hints),
        else => {},
    }
}

/// Compute the byte offset just past the end of an expression.
/// Simplified version of Validator.exprSpan for use in the handler.
fn exprEndOffset(expr: Ast.Expr) u32 {
    return switch (expr) {
        .ident => |e| e.loc +| @as(u32, @intCast(e.name.len)),
        .literal => |e| e.loc +| @as(u32, @intCast(e.value.len)),
        .binary => |e| exprEndOffset(e.right),
        .unary => |e| exprEndOffset(e.operand),
        .call => |e| if (e.end_loc > 0) e.end_loc else e.loc +| 1,
        .index => |e| if (e.end_loc > 0) e.end_loc else e.loc +| 1,
        .member => |e| e.loc +| 1 +| @as(u32, @intCast(e.member_name.len)),
        .paren => |e| exprEndOffset(e.expr),
    };
}

/// Collect expression type hints for interesting sub-expressions.
/// Only emits hints for binary ops (non-comparison), function calls (non-constructors),
/// member access, and indexing operations within the visible range.
fn collectExprTypeHints(
    self: *Handler,
    module: *const Ast.Module,
    expr_types: *const std.AutoHashMapUnmanaged(u32, wgslender.Validator.ExprTypeInfo),
    source: [:0]const u8,
    expr: Ast.Expr,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayListUnmanaged(InlayHintInfo),
    depth: u32,
) std.mem.Allocator.Error!void {
    if (depth > 8) return;

    // Look up by expression-specific loc (operator for binary, open-paren
    // for call, dot for member, bracket for index) — matches Validator keys.
    const key: ?u32 = switch (expr) {
        .binary => |e| e.loc,
        .call => |e| e.loc,
        .index => |e| e.loc,
        .member => |e| e.loc,
        else => null,
    };
    if (key) |k| {
        if (k >= range_start and k < range_end) {
            if (expr_types.get(k)) |info| {
                if (shouldShowExprHint(expr, info.typ)) {
                    if (info.end_offset >= range_start and info.end_offset <= range_end) {
                        const pos = offsetToLspPosition(source, info.end_offset) orelse return;
                        // Deduplicate: skip if a type hint already exists at
                        // this position (nested expressions sharing an end).
                        var duplicate = false;
                        for (hints.items) |h| {
                            if (h.kind == .type_hint and
                                h.position.line == pos.line and
                                h.position.character == pos.character)
                            {
                                duplicate = true;
                                break;
                            }
                        }
                        if (!duplicate) {
                            try hints.append(self.gpa, .{
                                .position = pos,
                                .label = info.typ.string(),
                                .kind = .type_hint,
                                .def_range = structDefRange(module, source, info.typ),
                            });
                        }
                    }
                }
            }
        }
    }

    // Recurse into sub-expressions
    switch (expr) {
        .binary => |e| {
            try self.collectExprTypeHints(module, expr_types, source, e.left, range_start, range_end, hints, depth + 1);
            try self.collectExprTypeHints(module, expr_types, source, e.right, range_start, range_end, hints, depth + 1);
        },
        .call => |e| {
            for (e.args.items) |arg| {
                try self.collectExprTypeHints(module, expr_types, source, arg, range_start, range_end, hints, depth + 1);
            }
        },
        .index => |e| {
            try self.collectExprTypeHints(module, expr_types, source, e.base, range_start, range_end, hints, depth + 1);
        },
        .member => |e| {
            try self.collectExprTypeHints(module, expr_types, source, e.base, range_start, range_end, hints, depth + 1);
        },
        .paren => |e| {
            try self.collectExprTypeHints(module, expr_types, source, e.expr, range_start, range_end, hints, depth + 1);
        },
        else => {},
    }
}

fn shouldShowExprHint(expr: Ast.Expr, typ: wgslender.Types.Type) bool {
    switch (expr) {
        .binary => |e| {
            // Skip comparison/logical operators — result is always bool, obvious
            switch (e.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => return false,
                else => {},
            }
        },
        .call => |e| {
            // Skip type constructors where the type is written in the syntax
            if (e.template_type != null) return false;
        },
        .member, .index => {},
        else => return false,
    }
    // Skip void
    if (typ == .void_type) return false;
    return true;
}

/// If `typ` is a struct, return the LSP range of its declaration name.
fn structDefRange(module: *const Ast.Module, source: [:0]const u8, typ: wgslender.Types.Type) ?Range {
    const name = switch (typ) {
        .@"struct" => |s| s.name,
        else => return null,
    };
    for (module.symbols.items) |sym| {
        if (sym.kind == .@"struct" and std.mem.eql(u8, sym.original_name, name)) {
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        }
    }
    return null;
}

fn exprStartOffset(expr: Ast.Expr) u32 {
    return switch (expr) {
        .ident => |e| e.loc,
        .literal => |e| e.loc,
        .binary => |e| exprStartOffset(e.left),
        .unary => |e| e.loc,
        .call => |e| if (e.func) |f| exprStartOffset(f) else e.loc,
        .index => |e| exprStartOffset(e.base),
        .member => |e| exprStartOffset(e.base),
        .paren => |e| exprStartOffset(e.expr),
    };
}

// =========================================================================
// LSP Feature: Unused Symbol Warnings
// =========================================================================

/// Append warnings for unused symbols to a diagnostics list.
/// Called after analysis to supplement validation diagnostics.
pub fn appendUnusedWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items, 0..) |sym, idx| {
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_api_facing) continue;
        if (sym.flags.is_external_binding) continue;

        // Only warn for user-declared symbols
        switch (sym.kind) {
            .function, .@"const", .let, .@"var", .override => {},
            .parameter => {
                // Skip parameters of entry point functions
                // We can't easily detect this from the symbol alone,
                // so skip all parameters for now (they may be required by signature)
                continue;
            },
            else => continue,
        }

        _ = idx;
        const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is declared but never used", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .warning,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0001",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}

/// Append hint-level diagnostics for symbols that are used internally
/// but not reachable from any entry point. Only emits when entry points exist.
pub fn appendDeadCodeWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    // Check if any entry points exist. If none, DCE conservatively marks
    // everything live (library mode), so there's nothing to warn about.
    var has_entry_points = false;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_entry_point) {
            has_entry_points = true;
            break;
        }
    }
    if (!has_entry_points) return;

    for (module.symbols.items) |sym| {
        // Only flag symbols that are used (use_count > 0) but not live
        if (sym.flags.is_live) continue;
        if (sym.use_count == 0) continue; // Already caught by appendUnusedWarnings
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_external_binding) continue;

        switch (sym.kind) {
            .function, .@"struct", .@"const", .let, .@"var", .override => {},
            else => continue,
        }

        const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is not reachable from any entry point", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .hint,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0002",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}

/// Append warnings for binding variables (@group/@binding) that are declared but never used.
/// These consume bind group layout slots even when unused.
pub fn appendUnusedBindingWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items) |sym| {
        if (!sym.flags.is_external_binding) continue;
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;

        const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "binding variable '{s}' is declared but never used — it will consume a bind group layout slot", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .warning,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0003",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}

// =========================================================================
// LSP Feature: Code Lens (reference counts)
// =========================================================================

pub const CodeLensInfo = struct {
    range: Range,
    title: []const u8,
    /// Optional command to invoke when the lens is clicked. Existing
    /// reference / binding / workgroup lenses leave this null and surface
    /// as plain title-only lenses (`command = ""` in the LSP wire shape).
    /// The total-size lens sets it to `wgslender.showMinifiedOutput`.
    command: ?[]const u8 = null,
    /// JSON arguments forwarded to the command. Owned by the same
    /// allocator as `title`; `freeCodeLens` releases both. The
    /// individual `std.json.Value` entries are leaf values that own
    /// no further allocations (we only stamp `.string` URIs today),
    /// so freeing the slice is sufficient.
    arguments: ?[]std.json.Value = null,
};

pub fn freeCodeLens(gpa: std.mem.Allocator, lenses: []const CodeLensInfo) void {
    for (lenses) |l| {
        gpa.free(l.title);
        if (l.arguments) |args| {
            for (args) |arg| switch (arg) {
                .string => |s| gpa.free(s),
                else => {},
            };
            gpa.free(args);
        }
    }
    gpa.free(lenses);
}

pub fn computeCodeLens(self: *Handler, uri: []const u8) ![]CodeLensInfo {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var lenses: std.ArrayListUnmanaged(CodeLensInfo) = .empty;
    defer lenses.deinit(self.gpa);

    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        // Only show code lens for functions and structs
        switch (decl) {
            .function, .@"struct" => {},
            else => continue,
        }

        // Count references (use the shared library reference collector)
        const refs = Edits.findReferences(self.gpa, module, name_ref, false) catch continue;
        defer self.gpa.free(refs);

        const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "{d} reference{s}", .{ refs.len, if (refs.len == 1) "" else "s" }) catch continue;
        try lenses.append(self.gpa, .{
            .range = range,
            .title = try self.gpa.dupe(u8, title),
        });
    }

    // Add binding summary and workgroup size lenses for entry points.
    // `binding_summary` is the shared template; each lens gets its own
    // duped copy so the caller can free `l.title` uniformly without
    // double-freeing across entry points (and without leaking when the
    // module has bindings but no entry points consume the template).
    const binding_summary = collectBindingSummary(self.gpa, module);
    defer if (binding_summary) |s| self.gpa.free(s);
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!sym.flags.is_entry_point) continue;
                const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;

                if (binding_summary) |summary| {
                    const title = try self.gpa.dupe(u8, summary);
                    try lenses.append(self.gpa, .{ .range = range, .title = title });
                }

                // Workgroup size for compute shaders
                if (getWorkgroupSize(f, &analysis.const_values, module)) |wg| {
                    var wg_buf: [64]u8 = undefined;
                    const wg_title = std.fmt.bufPrint(&wg_buf, "workgroup: {d}x{d}x{d}", .{ wg[0], wg[1], wg[2] }) catch continue;
                    try lenses.append(self.gpa, .{
                        .range = range,
                        .title = try self.gpa.dupe(u8, wg_title),
                    });
                }
            },
            else => {},
        }
    }

    // Phase 6: module-level total-size lens. Only when the resolved
    // mode requests the total (insights / strict, with the
    // `totalSize` sub-switch on by default — matches the inlay-hints
    // gating). Estimator runs in a scratch arena so its hash maps don't
    // outlive this call; we copy out only the four u32s and the click
    // command into the returned lens.
    if (self.effectiveMinifyFor(uri).insights.total_size) {
        self.appendTotalSizeLens(uri, source, &lenses) catch |err| switch (err) {
            error.OutOfMemory => return err,
        };
    }

    return try self.gpa.dupe(CodeLensInfo, lenses.items);
}

/// Phase 6 — append the module-level total-size code lens.
///
/// Title shape: `"<src> B → <min> B min → <gz> B gz"`, with a
/// ` (over budget)` suffix when an `Effective.budget_bytes` is set
/// and the estimator's `total_min` exceeds it. ASCII-only badge for
/// client renderer portability (see plan §"Decisions resolved").
///
/// Click target: `wgslender.showMinifiedOutput`, with `[uri]` as the
/// argument. The command produces the actual minified text via
/// `Minifier.minify`; the lens itself only relies on the cheap
/// estimator.
fn appendTotalSizeLens(
    self: *Handler,
    uri: []const u8,
    source: [:0]const u8,
    lenses: *std.ArrayListUnmanaged(CodeLensInfo),
) !void {
    // Phase 7 — read through the per-document cache. The first
    // codeLens / inlayHint / minify-lint pass after a parse-version
    // bump pays the estimator cost; subsequent ones in the same
    // version return the same pointer.
    const result = self.getMinifyEstimate(uri, self.estimatorOptionsFor(uri)) catch return;

    const eff = self.effectiveMinifyFor(uri);
    const original: u32 = @intCast(source.len);
    const over_budget: bool = if (eff.budget_bytes) |b| result.total_min > b else false;

    var buf: [128]u8 = undefined;
    const title = if (over_budget)
        std.fmt.bufPrint(
            &buf,
            "{d} B \u{2192} {d} B min \u{2192} {d} B gz (over budget)",
            .{ original, result.total_min, result.total_gz },
        ) catch return
    else
        std.fmt.bufPrint(
            &buf,
            "{d} B \u{2192} {d} B min \u{2192} {d} B gz",
            .{ original, result.total_min, result.total_gz },
        ) catch return;

    const title_dup = try self.gpa.dupe(u8, title);
    errdefer self.gpa.free(title_dup);

    const uri_dup = try self.gpa.dupe(u8, uri);
    errdefer self.gpa.free(uri_dup);

    const args = try self.gpa.alloc(std.json.Value, 1);
    errdefer self.gpa.free(args);
    args[0] = .{ .string = uri_dup };

    try lenses.append(self.gpa, .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
        .title = title_dup,
        .command = "wgslender.showMinifiedOutput",
        .arguments = args,
    });
}

/// Collect a one-line summary of all @group/@binding declarations in the module.
fn collectBindingSummary(gpa: std.mem.Allocator, module: *const Ast.Module) ?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var scratch: [128]u8 = undefined;
    var count: usize = 0;

    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"var" => |v| {
                if (!v.name.isValid()) continue;

                // Extract group and binding from attributes
                var group: ?i32 = null;
                var binding: ?i32 = null;
                for (v.attributes.items) |attr| {
                    if (std.mem.eql(u8, attr.name, "group")) {
                        group = getIntArg(attr);
                    } else if (std.mem.eql(u8, attr.name, "binding")) {
                        binding = getIntArg(attr);
                    }
                }

                if (group != null and binding != null) {
                    if (count > 0) out.appendSlice(gpa, " | ") catch {};
                    // Show address space for uniform/storage, or type name for sampler/texture
                    const type_label: []const u8 = if (v.address_space != .none)
                        v.address_space.string()
                    else if (v.typ) |typ| switch (typ) {
                        .sampler => "sampler",
                        .texture => "texture",
                        .ident => |t| t.name,
                        else => "var",
                    } else "var";
                    const entry = std.fmt.bufPrint(&scratch, "@group({d}) @binding({d}) {s}", .{ group.?, binding.?, type_label }) catch continue;
                    out.appendSlice(gpa, entry) catch {};
                    count += 1;
                }
            },
            else => {},
        }
    }

    if (count == 0) return null;
    return gpa.dupe(u8, out.items) catch null;
}

/// Extract @workgroup_size(X, Y, Z) from a function's attributes.
/// Resolves const references via const_values when available.
/// Needs the module to resolve unbound ident refs by name lookup.
fn getWorkgroupSize(f: *const Ast.FunctionDecl, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module) ?[3]u32 {
    for (f.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            var sizes = [3]u32{ 1, 1, 1 };
            for (attr.args.items, 0..) |arg, i| {
                if (i >= 3) break;
                sizes[i] = resolveConstIntExpr(arg, const_values, module) orelse 1;
            }
            return sizes;
        }
    }
    return null;
}

/// Resolve a const-evaluable expression to a u32 value.
/// Handles literals and const identifier references via the const_values map.
/// Falls back to name-based lookup in the module when ident refs are unbound
/// (e.g., in attribute arguments which don't go through the parser's bind pass).
fn resolveConstIntExpr(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module) ?u32 {
    return resolveConstIntExprDepth(expr, const_values, module, 0);
}

fn resolveConstIntExprDepth(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module, depth: u32) ?u32 {
    if (depth > 32) return null;
    switch (expr) {
        .literal => |lit| {
            var val_str = lit.value;
            if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
                val_str = val_str[0 .. val_str.len - 1];
            }
            const val = std.fmt.parseInt(i64, val_str, 0) catch return null;
            if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
            return null;
        },
        .ident => |ident| {
            // Try direct ref lookup first (bound idents)
            if (ident.ref.isValid()) {
                if (const_values.get(ident.ref.index())) |val| {
                    if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
                }
            }
            // Fallback: look up by name in module symbols (for unbound attribute args)
            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.kind == .@"const" and std.mem.eql(u8, sym.original_name, ident.name)) {
                    if (const_values.get(@intCast(idx))) |val| {
                        if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
                    }
                    break;
                }
            }
            return null;
        },
        .paren => |p| return resolveConstIntExprDepth(p.expr, const_values, module, depth + 1),
        .unary => |u| {
            if (u.op == .neg) {
                // Negative values aren't valid for workgroup sizes etc., but resolve anyway
                return null;
            }
            return null;
        },
        .binary => |b| {
            const l = resolveConstIntExprDepth(b.left, const_values, module, depth + 1) orelse return null;
            const r = resolveConstIntExprDepth(b.right, const_values, module, depth + 1) orelse return null;
            const li: i64 = @intCast(l);
            const ri: i64 = @intCast(r);
            const result: i64 = switch (b.op) {
                .add => li +| ri,
                .sub => li -| ri,
                .mul => li *| ri,
                .div => if (ri != 0) @divTrunc(li, ri) else return null,
                .mod => if (ri != 0) @mod(li, ri) else return null,
                .shl => if (ri >= 0 and ri < 64) li << @intCast(ri) else return null,
                .shr => if (ri >= 0 and ri < 64) li >> @intCast(ri) else return null,
                .@"and" => li & ri,
                .@"or" => li | ri,
                .xor => li ^ ri,
                else => return null,
            };
            if (result >= 0 and result <= std.math.maxInt(u32)) return @intCast(result);
            return null;
        },
        else => return null,
    }
}

/// Resolve a const-evaluable expression to an i64 value for display purposes.
/// Handles literals, const ident refs, parens, negation, and binary arithmetic.
pub fn resolveConstExpr(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64)) ?i64 {
    return resolveConstExprDepth(expr, const_values, 0);
}

fn resolveConstExprDepth(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), depth: u32) ?i64 {
    if (depth > 32) return null;
    return switch (expr) {
        .literal => |lit| {
            var val_str = lit.value;
            if (val_str.len == 0) return @as(i64, 0);
            if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
                val_str = val_str[0 .. val_str.len - 1];
            }
            return std.fmt.parseInt(i64, val_str, 0) catch null;
        },
        .ident => |ident| {
            if (ident.ref.isValid()) return const_values.get(ident.ref.index());
            return null;
        },
        .paren => |p| resolveConstExprDepth(p.expr, const_values, depth + 1),
        .unary => |u| {
            const val = resolveConstExprDepth(u.operand, const_values, depth + 1) orelse return null;
            return switch (u.op) {
                .neg => 0 -| val,
                .bit_not => ~val,
                else => null,
            };
        },
        .binary => |b| {
            const l = resolveConstExprDepth(b.left, const_values, depth + 1) orelse return null;
            const r = resolveConstExprDepth(b.right, const_values, depth + 1) orelse return null;
            return switch (b.op) {
                .add => l +| r,
                .sub => l -| r,
                .mul => l *| r,
                .div => if (r != 0) @divTrunc(l, r) else null,
                .mod => if (r != 0) @mod(l, r) else null,
                .shl => if (r >= 0 and r < 64) l << @intCast(r) else null,
                .shr => if (r >= 0 and r < 64) l >> @intCast(r) else null,
                .@"and" => l & r,
                .@"or" => l | r,
                .xor => l ^ r,
                else => null,
            };
        },
        else => null,
    };
}

/// Extract an integer value from the first argument of an attribute.
fn getIntArg(attr: Ast.Attribute) ?i32 {
    if (attr.args.items.len == 0) return null;
    switch (attr.args.items[0]) {
        .literal => |lit| return std.fmt.parseInt(i32, lit.value, 10) catch null,
        else => return null,
    }
}

// =========================================================================
// LSP Feature: Incremental Text Sync
// =========================================================================

/// Apply an incremental text change to an open document.
/// The range specifies which portion of the source to replace.
///
/// Fast path: if the edit only affects trivia (whitespace / comments),
/// the cached `AnalysisResult` is left in place — the source bytes are
/// updated but no validator work is scheduled. Semantic edits fall back
/// to the classic invalidate-and-reanalyze behavior.
pub fn changeDocumentIncremental(self: *Handler, uri: []const u8, range: Range, text: []const u8) !void {
    const doc = self.documents.getPtr(uri) orelse return;
    const old_source = doc.source;

    const start = lspPositionToOffset(old_source, range.start) orelse {
        self.invalidateAnalysis(uri);
        return;
    };
    const end = lspPositionToOffset(old_source, range.end) orelse {
        self.invalidateAnalysis(uri);
        return;
    };
    if (end < start) {
        self.invalidateAnalysis(uri);
        return;
    }

    // Build new source: source[0..start] ++ text ++ source[end..]
    const new_len = start + text.len + (old_source.len - end);
    const new_source = try self.gpa.alloc(u8, new_len);
    errdefer self.gpa.free(new_source);
    @memcpy(new_source[0..start], old_source[0..start]);
    @memcpy(new_source[start..][0..text.len], text);
    @memcpy(new_source[start + text.len ..], old_source[end..]);

    // Classify before swapping: if non-trivia tokens didn't change, the
    // cached analysis is still correct against the new source (analysis
    // holds its own sentinel-terminated source copy and AST byte offsets
    // remain valid because they index into `doc.analysis_source`, not
    // `doc.source`). Just swap buffers.
    const old_z = self.gpa.dupeZ(u8, old_source) catch null;
    defer if (old_z) |z| self.gpa.free(z);
    const new_z = self.gpa.dupeZ(u8, new_source) catch null;
    defer if (new_z) |z| self.gpa.free(z);

    const classification: wgslender.Incremental.EditKind = blk: {
        if (old_z == null or new_z == null) break :blk .semantic;
        break :blk wgslender.Incremental.classifyEdit(self.gpa, old_z.?, new_z.?) catch .semantic;
    };

    switch (classification) {
        .no_op => {
            // Textually identical — discard the (byte-identical) new buffer
            // and skip the reparse pipeline entirely. `doc.parse` stays
            // pointing at the unchanged tree; cache stays hot.
            self.gpa.free(new_source);
            return;
        },
        .trivia_only => {
            // Keep the cached analysis — module_version preservation in
            // `updateParseAfterEdit` will honor this when the trivia
            // shortcut fires. If the reparse takes a non-shortcut path,
            // the version bump will invalidate the cache.
            self.gpa.free(doc.source);
            doc.source = new_source;
        },
        .semantic => {
            // Analysis invalidation is handled by `updateParseAfterEdit`
            // (it runs before `prev.deinit` so cached pointers into
            // `prev.arena` get freed at the right time). Just swap the
            // source bytes here.
            self.gpa.free(doc.source);
            doc.source = new_source;
        },
    }

    // Keep `doc.parse` (CST + AST) in sync with `doc.source`. The
    // `module_version` on the returned result tells us whether the
    // cached analysis can survive (trivia shortcut → preserved; any
    // other path → invalidated before `prev` is torn down).
    self.updateParseAfterEdit(doc, .{
        .start = @intCast(start),
        .end = @intCast(end),
        .new_text = text,
    });
    // Magic-comment scan reads `doc.source` directly; re-run after any
    // source mutation so the cached layer tracks the current document.
    self.rebuildMagic(doc);
}

fn updateParseAfterEdit(self: *Handler, doc: *Document, edit: wgslender.Incremental.Edit) void {
    if (doc.parse) |*prev| {
        const prev_version = prev.module_version;
        const updated = wgslender.Incremental.reparse(self.gpa, prev, edit) catch {
            // Reparse failed — the analysis (if any) held pointers into
            // `prev.arena`, which is about to be deinit'd. Invalidate
            // first so we don't leave a dangling cache.
            self.invalidateAnalysisAt(doc);
            prev.deinit();
            doc.parse = null;
            return;
        };

        if (updated.module_version != prev_version) {
            // Any non-trivia-shortcut path bumps module_version. The
            // cached symbol/struct/expr types all index off the module
            // whose layout has changed; drop the cache before `prev`
            // (and therefore prev.arena) is torn down.
            self.invalidateAnalysisAt(doc);
        } else if (doc.analysis) |a| {
            // Trivia shortcut fired. `module.source` got repointed at
            // the new arena-owned bytes (see `tryTriviaOnlyShortcut`),
            // but the cached diagnostics still reference the pre-edit
            // bytes for line/column rendering. Rebuild the line index
            // against the new source so future diagnostic formatting
            // produces correct coordinates.
            if (a._arena) |*ana_arena| {
                const ana_alloc = ana_arena.allocator();
                a.diagnostics.source = updated.module.source;
                a.diagnostics.line_index.deinit(ana_alloc);
                if (wgslender.Diagnostic.LineIndex.init(ana_alloc, updated.module.source)) |idx| {
                    a.diagnostics.line_index = idx;
                } else |_| {
                    // Line-index rebuild failed — safest to drop the
                    // cache rather than leave a half-updated one.
                    self.invalidateAnalysisAt(doc);
                }
            }
        }

        prev.deinit();
        doc.parse = updated;
        return;
    }
    self.rebuildParse(doc);
}

// =========================================================================
// LSP Feature: Formatting
// =========================================================================

const Printer = wgslender.Printer;

pub fn computeFormatting(self: *Handler, uri: []const u8) !?LspTextEdit {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;

    // Parse and print with non-minified settings
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);

    var options = wgslender.Minifier.defaultOptions();
    options.minify_whitespace = false;
    options.minify_identifiers = false;

    var result = try wgslender.minifyWithOptions(self.gpa, source_z, options);
    defer result.deinit(self.gpa);

    if (result.errors.len > 0) return null; // Can't format with parse errors

    // Compute the end position of the document
    const end_pos = offsetToLspPosition(source, @intCast(source.len)) orelse return null;

    return .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = end_pos,
        },
        .new_text = try self.gpa.dupe(u8, result.code),
    };
}

// =========================================================================
// LSP Feature: Semantic Tokens
// =========================================================================

// Token types: indices into the legend
const SemanticTokenType = enum(u32) {
    keyword = 0,
    function = 1,
    @"struct" = 2,
    parameter = 3,
    variable = 4,
    number = 5,
    type_name = 6,
    comment = 7,
    decorator = 8,
};

pub const semantic_token_types = [_][]const u8{
    "keyword", "function", "struct",  "parameter", "variable",
    "number",  "type",     "comment", "decorator",
};

pub const semantic_token_modifiers = [_][]const u8{
    "declaration", "readonly", "defaultLibrary",
};

// Modifier bitmasks
const MOD_DECLARATION: u32 = 1;
const MOD_READONLY: u32 = 2;
const MOD_DEFAULT_LIBRARY: u32 = 4;

pub fn computeSemanticTokens(self: *Handler, uri: []const u8) ![]u32 {
    const doc = self.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;

    // Tokenize
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);
    var tokens_storage = wgslender.Lexer.tokenize(self.gpa, source_z) catch return &.{};
    defer tokens_storage.deinit(self.gpa);
    const tags = tokens_storage.items(.tag);
    const starts = tokens_storage.items(.start);

    // Try to get analysis for symbol resolution
    const analysis = self.analyzeDocument(uri) catch null;
    const module = if (analysis) |a| a.module else null;

    // Build semantic token data (groups of 5: deltaLine, deltaStartChar, length, tokenType, tokenModifiers)
    var data: std.ArrayListUnmanaged(u32) = .empty;
    defer data.deinit(self.gpa);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    // First, scan for comments and collect them
    var comment_ranges: std.ArrayListUnmanaged(struct { start: u32, end: u32 }) = .empty;
    defer comment_ranges.deinit(self.gpa);
    {
        var i: u32 = 0;
        while (i < source.len) {
            if (source[i] == '/' and i + 1 < source.len) {
                if (source[i + 1] == '/') {
                    // Line comment
                    const cstart = i;
                    while (i < source.len and source[i] != '\n') i += 1;
                    comment_ranges.append(self.gpa, .{ .start = cstart, .end = i }) catch {};
                } else if (source[i + 1] == '*') {
                    // Block comment (WGSL nests)
                    const cstart = i;
                    i += 2;
                    var depth: u32 = 1;
                    while (i + 1 < source.len and depth > 0) {
                        if (source[i] == '/' and source[i + 1] == '*') {
                            depth += 1;
                            i += 2;
                        } else if (source[i] == '*' and source[i + 1] == '/') {
                            depth -= 1;
                            i += 2;
                        } else i += 1;
                    }
                    comment_ranges.append(self.gpa, .{ .start = cstart, .end = i }) catch {};
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
    }

    // Emit comment tokens first-pass style: interleave with regular tokens
    // For simplicity, process tokens and comments in source order
    var comment_idx: usize = 0;

    for (tags, 0..) |tag, ti| {
        if (tag == .eof or tag == .@"error") break;
        const tok_start = starts[ti];

        // Emit any comments that appear before this token
        while (comment_idx < comment_ranges.items.len and comment_ranges.items[comment_idx].start < tok_start) {
            const cr = comment_ranges.items[comment_idx];
            emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, cr.start, cr.end - cr.start, @intFromEnum(SemanticTokenType.comment), 0);
            comment_idx += 1;
        }

        const tok_len = tokenLength(source_z, tok_start, tag);
        if (tok_len == 0) continue;

        switch (tag) {
            // Keywords
            .keyword_alias,
            .keyword_break,
            .keyword_case,
            .keyword_const,
            .keyword_const_assert,
            .keyword_continue,
            .keyword_continuing,
            .keyword_default,
            .keyword_diagnostic,
            .keyword_discard,
            .keyword_else,
            .keyword_enable,
            .keyword_fn,
            .keyword_for,
            .keyword_if,
            .keyword_let,
            .keyword_loop,
            .keyword_override,
            .keyword_requires,
            .keyword_return,
            .keyword_struct,
            .keyword_switch,
            .keyword_var,
            .keyword_while,
            => {
                emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.keyword), 0);
            },
            .true_literal, .false_literal => {
                emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.keyword), MOD_READONLY);
            },
            .int_literal, .float_literal => {
                emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.number), 0);
            },
            .at => {
                emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.decorator), 0);
            },
            .ident => {
                const name = identAt(source_z, tok_start);
                if (name.len == 0) continue;

                // Check if it's a builtin function
                if (Builtins.lookup(name) != null) {
                    emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.function), MOD_DEFAULT_LIBRARY);
                    continue;
                }

                // Try to resolve via AST
                if (module) |m| {
                    if (resolveIdentSymbol(m, tok_start, name)) |sym| {
                        const tok_type: u32 = switch (sym.kind) {
                            .function => @intFromEnum(SemanticTokenType.function),
                            .@"struct" => @intFromEnum(SemanticTokenType.@"struct"),
                            .parameter => @intFromEnum(SemanticTokenType.parameter),
                            .@"const", .override => @intFromEnum(SemanticTokenType.variable),
                            .let, .@"var" => @intFromEnum(SemanticTokenType.variable),
                            else => @intFromEnum(SemanticTokenType.variable),
                        };
                        var mods: u32 = 0;
                        if (sym.kind == .@"const" or sym.kind == .override) mods |= MOD_READONLY;
                        if (sym.loc == tok_start) mods |= MOD_DECLARATION;
                        emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, tok_type, mods);
                        continue;
                    }
                }

                // Check if it's a builtin type name
                if (isBuiltinTypeName(name)) {
                    emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, tok_start, tok_len, @intFromEnum(SemanticTokenType.type_name), MOD_DEFAULT_LIBRARY);
                    continue;
                }

                // Unresolved identifier — skip
            },
            else => {},
        }
    }

    // Emit any trailing comments
    while (comment_idx < comment_ranges.items.len) {
        const cr = comment_ranges.items[comment_idx];
        emitSemanticToken(self.gpa, source, &data, &prev_line, &prev_char, cr.start, cr.end - cr.start, @intFromEnum(SemanticTokenType.comment), 0);
        comment_idx += 1;
    }

    return try self.gpa.dupe(u32, data.items);
}

fn emitSemanticToken(
    gpa: std.mem.Allocator,
    source: []const u8,
    data: *std.ArrayListUnmanaged(u32),
    prev_line: *u32,
    prev_char: *u32,
    start: u32,
    length: u32,
    token_type: u32,
    modifiers: u32,
) void {
    const pos = offsetToLspPosition(source, start) orelse return;
    const delta_line = pos.line - prev_line.*;
    const delta_char = if (delta_line == 0) pos.character - prev_char.* else pos.character;
    data.appendSlice(gpa, &.{ delta_line, delta_char, length, token_type, modifiers }) catch return;
    prev_line.* = pos.line;
    prev_char.* = pos.character;
}

fn tokenLength(source: [:0]const u8, start: u32, tag: Lexer.Tag) u32 {
    return switch (tag) {
        .ident, .reserved_ident => @intCast(identAt(source, start).len),
        .int_literal, .float_literal => blk: {
            var i = start;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '.' or source[i] == '_' or source[i] == 'x' or source[i] == 'X' or source[i] == '+' or source[i] == '-')) {
                // Handle hex prefix and exponent signs carefully
                if ((source[i] == '+' or source[i] == '-') and i > start) {
                    const prev = source[i - 1];
                    if (prev != 'e' and prev != 'E' and prev != 'p' and prev != 'P') break;
                }
                i += 1;
            }
            break :blk i - start;
        },
        .true_literal => 4,
        .false_literal => 5,
        .at => 1,
        // Keywords — get length from the keyword string
        .keyword_alias => 5,
        .keyword_break => 5,
        .keyword_case => 4,
        .keyword_const => 5,
        .keyword_const_assert => 12,
        .keyword_continue => 8,
        .keyword_continuing => 10,
        .keyword_default => 7,
        .keyword_diagnostic => 10,
        .keyword_discard => 7,
        .keyword_else => 4,
        .keyword_enable => 6,
        .keyword_fn => 2,
        .keyword_for => 3,
        .keyword_if => 2,
        .keyword_let => 3,
        .keyword_loop => 4,
        .keyword_override => 8,
        .keyword_requires => 8,
        .keyword_return => 6,
        .keyword_struct => 6,
        .keyword_switch => 6,
        .keyword_var => 3,
        .keyword_while => 5,
        else => 0,
    };
}

fn identAt(source: [:0]const u8, start: u32) []const u8 {
    var end = start;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) end += 1;
    return source[start..end];
}

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

fn isBuiltinTypeName(name: []const u8) bool {
    for (&wgsl_type_names) |tn| {
        if (std.mem.eql(u8, name, tn)) return true;
    }
    return false;
}

// =========================================================================
// LSP Feature: Selection Range
// =========================================================================

pub const SelectionRangeInfo = struct {
    range: Range,
    parent: ?*const SelectionRangeInfo,
};

pub fn computeSelectionRange(self: *Handler, uri: []const u8, position: Position) !?*SelectionRangeInfo {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    // Build chain from innermost to outermost:
    // 1. Whole file (always the outermost)
    const file_range = offsetRangeToLspRange(source, 0, @intCast(source.len)) orelse return null;
    const file_node = try self.gpa.create(SelectionRangeInfo);
    file_node.* = .{ .range = file_range, .parent = null };

    // 2. Find which declaration contains the offset
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (f.body == null) continue;
                // Check if offset is within this function's range
                const end_offset = findClosingBrace(source, sym.loc) orelse continue;
                if (offset < sym.loc or offset > end_offset) continue;

                // Function declaration range
                const fn_range = offsetRangeToLspRange(source, sym.loc, end_offset + 1) orelse continue;
                const fn_node = try self.gpa.create(SelectionRangeInfo);
                fn_node.* = .{ .range = fn_range, .parent = file_node };

                // Name range
                const name_range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
                if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
                    const name_node = try self.gpa.create(SelectionRangeInfo);
                    name_node.* = .{ .range = name_range, .parent = fn_node };
                    return name_node;
                }

                return fn_node;
            },
            .@"struct" => |s| {
                if (!s.name.isValid()) continue;
                const sym = module.symbols.items[s.name.index()];
                const end_offset = findClosingBrace(source, sym.loc) orelse continue;
                if (offset < sym.loc or offset > end_offset) continue;

                const struct_range = offsetRangeToLspRange(source, sym.loc, end_offset + 1) orelse continue;
                const struct_node = try self.gpa.create(SelectionRangeInfo);
                struct_node.* = .{ .range = struct_range, .parent = file_node };
                return struct_node;
            },
            else => {
                const name_ref = decl.nameRef();
                if (!name_ref.isValid()) continue;
                const sym = module.symbols.items[name_ref.index()];
                if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
                    const range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
                    const node = try self.gpa.create(SelectionRangeInfo);
                    node.* = .{ .range = range, .parent = file_node };
                    return node;
                }
            },
        }
    }

    return file_node;
}

// =========================================================================
// LSP Feature: Call Hierarchy
// =========================================================================

pub const CallHierarchyItem = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
};

pub const IncomingCall = struct {
    from: CallHierarchyItem,
    from_ranges: []const Range,
};

pub const OutgoingCall = struct {
    to: CallHierarchyItem,
    from_ranges: []const Range,
};

pub fn prepareCallHierarchy(self: *Handler, uri: []const u8, position: Position) !?CallHierarchyItem {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    const sym_idx: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        else => return null,
    };
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (sym.kind != .function) return null;

    const sel_range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse return null;
    return .{
        .name = sym.original_name,
        .kind = .function,
        .range = sel_range,
        .selection_range = sel_range,
    };
}

pub fn computeIncomingCalls(self: *Handler, uri: []const u8, target_name: []const u8) ![]IncomingCall {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var calls: std.ArrayListUnmanaged(IncomingCall) = .empty;
    defer calls.deinit(self.gpa);

    // For each function, check if it calls the target
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                if (f.body == null) continue;
                const caller_sym = module.symbols.items[f.name.index()];
                if (std.mem.eql(u8, caller_sym.original_name, target_name)) continue; // skip self

                // Scan for calls to target in this function body
                var call_locs: std.ArrayListUnmanaged(Range) = .empty;
                defer call_locs.deinit(self.gpa);
                findCallsInCompound(self.gpa, module, f.body.?, target_name, source, &call_locs);

                if (call_locs.items.len > 0) {
                    const sel_range = offsetRangeToLspRange(source, caller_sym.loc, caller_sym.loc + @as(u32, @intCast(caller_sym.original_name.len))) orelse continue;
                    try calls.append(self.gpa, .{
                        .from = .{
                            .name = caller_sym.original_name,
                            .kind = .function,
                            .range = sel_range,
                            .selection_range = sel_range,
                        },
                        .from_ranges = try self.gpa.dupe(Range, call_locs.items),
                    });
                }
            },
            else => {},
        }
    }

    return try self.gpa.dupe(IncomingCall, calls.items);
}

pub fn computeOutgoingCalls(self: *Handler, uri: []const u8, caller_name: []const u8) ![]OutgoingCall {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    // Find the caller function
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                if (f.body == null) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!std.mem.eql(u8, sym.original_name, caller_name)) continue;

                // Collect all outgoing calls
                var calls_map = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Range)){};
                defer {
                    var it = calls_map.iterator();
                    while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
                    calls_map.deinit(self.gpa);
                }

                collectOutgoingCalls(self.gpa, module, f.body.?, source, &calls_map);

                var results: std.ArrayListUnmanaged(OutgoingCall) = .empty;
                defer results.deinit(self.gpa);

                var it = calls_map.iterator();
                while (it.next()) |entry| {
                    const callee_name = entry.key_ptr.*;
                    // Find callee symbol for range info
                    for (module.symbols.items) |callee_sym| {
                        if (std.mem.eql(u8, callee_sym.original_name, callee_name) and callee_sym.kind == .function) {
                            const sel_range = offsetRangeToLspRange(source, callee_sym.loc, callee_sym.loc + @as(u32, @intCast(callee_sym.original_name.len))) orelse break;
                            results.append(self.gpa, .{
                                .to = .{
                                    .name = callee_name,
                                    .kind = .function,
                                    .range = sel_range,
                                    .selection_range = sel_range,
                                },
                                .from_ranges = self.gpa.dupe(Range, entry.value_ptr.items) catch &.{},
                            }) catch {};
                            break;
                        }
                    }
                }

                return try self.gpa.dupe(OutgoingCall, results.items);
            },
            else => {},
        }
    }
    return &.{};
}

fn findCallsInCompound(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    compound: *const Ast.CompoundStmt,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayListUnmanaged(Range),
) void {
    for (compound.stmts.items) |stmt| {
        findCallsInStmt(gpa, module, stmt, target_name, source, locations);
    }
}

fn findCallsInStmt(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    stmt: Ast.Stmt,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayListUnmanaged(Range),
) void {
    switch (stmt) {
        .compound => |c| findCallsInCompound(gpa, module, c, target_name, source, locations),
        .@"return" => |r| {
            if (r.value) |v| findCallsInExprTree(gpa, module, v, target_name, source, locations);
        },
        .@"if" => |i| {
            findCallsInExprTree(gpa, module, i.condition, target_name, source, locations);
            findCallsInCompound(gpa, module, i.body, target_name, source, locations);
            if (i.else_branch) |eb| findCallsInStmt(gpa, module, eb, target_name, source, locations);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| findCallsInStmt(gpa, module, init_s, target_name, source, locations);
            if (f.condition) |cond| findCallsInExprTree(gpa, module, cond, target_name, source, locations);
            if (f.update) |upd| findCallsInStmt(gpa, module, upd, target_name, source, locations);
            findCallsInCompound(gpa, module, f.body, target_name, source, locations);
        },
        .@"while" => |w| {
            findCallsInExprTree(gpa, module, w.condition, target_name, source, locations);
            findCallsInCompound(gpa, module, w.body, target_name, source, locations);
        },
        .loop => |l| {
            findCallsInCompound(gpa, module, l.body, target_name, source, locations);
            if (l.continuing) |cont| findCallsInCompound(gpa, module, cont, target_name, source, locations);
        },
        .assign => |a| {
            findCallsInExprTree(gpa, module, a.left, target_name, source, locations);
            findCallsInExprTree(gpa, module, a.right, target_name, source, locations);
        },
        .call => |c| findCallsInExprTree(gpa, module, .{ .call = c.call }, target_name, source, locations),
        .decl => |d| {
            switch (d.decl) {
                .let => |l| {
                    if (l.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                .@"var" => |v| {
                    if (v.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                .@"const" => |cc| {
                    if (cc.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                else => {},
            }
        },
        .incr_decr => |i| findCallsInExprTree(gpa, module, i.expr, target_name, source, locations),
        .break_if => |b| findCallsInExprTree(gpa, module, b.condition, target_name, source, locations),
        else => {},
    }
}

fn findCallsInExprTree(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    expr: Ast.Expr,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayListUnmanaged(Range),
) void {
    switch (expr) {
        .call => |e| {
            if (e.func) |func| {
                switch (func) {
                    .ident => |id| {
                        if (std.mem.eql(u8, id.name, target_name)) {
                            if (offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)))) |range| {
                                locations.append(gpa, range) catch {};
                            }
                        }
                    },
                    else => {},
                }
                findCallsInExprTree(gpa, module, func, target_name, source, locations);
            }
            for (e.args.items) |arg| findCallsInExprTree(gpa, module, arg, target_name, source, locations);
        },
        .binary => |e| {
            findCallsInExprTree(gpa, module, e.left, target_name, source, locations);
            findCallsInExprTree(gpa, module, e.right, target_name, source, locations);
        },
        .unary => |e| findCallsInExprTree(gpa, module, e.operand, target_name, source, locations),
        .index => |e| {
            findCallsInExprTree(gpa, module, e.base, target_name, source, locations);
            findCallsInExprTree(gpa, module, e.idx, target_name, source, locations);
        },
        .paren => |e| findCallsInExprTree(gpa, module, e.expr, target_name, source, locations),
        .member => |e| findCallsInExprTree(gpa, module, e.base, target_name, source, locations),
        .ident, .literal => {},
    }
}

fn collectOutgoingCalls(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    compound: *const Ast.CompoundStmt,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Range)),
) void {
    for (compound.stmts.items) |stmt| {
        collectOutgoingCallsStmt(gpa, module, stmt, source, calls_map);
    }
}

fn collectOutgoingCallsStmt(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    stmt: Ast.Stmt,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Range)),
) void {
    switch (stmt) {
        .compound => |c| collectOutgoingCalls(gpa, module, c, source, calls_map),
        .@"return" => |r| {
            if (r.value) |v| collectOutgoingCallsExpr(gpa, module, v, source, calls_map);
        },
        .@"if" => |i| {
            collectOutgoingCallsExpr(gpa, module, i.condition, source, calls_map);
            collectOutgoingCalls(gpa, module, i.body, source, calls_map);
            if (i.else_branch) |eb| collectOutgoingCallsStmt(gpa, module, eb, source, calls_map);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| collectOutgoingCallsStmt(gpa, module, init_s, source, calls_map);
            if (f.condition) |cond| collectOutgoingCallsExpr(gpa, module, cond, source, calls_map);
            if (f.update) |upd| collectOutgoingCallsStmt(gpa, module, upd, source, calls_map);
            collectOutgoingCalls(gpa, module, f.body, source, calls_map);
        },
        .@"while" => |w| {
            collectOutgoingCallsExpr(gpa, module, w.condition, source, calls_map);
            collectOutgoingCalls(gpa, module, w.body, source, calls_map);
        },
        .loop => |l| {
            collectOutgoingCalls(gpa, module, l.body, source, calls_map);
            if (l.continuing) |cont| collectOutgoingCalls(gpa, module, cont, source, calls_map);
        },
        .assign => |a| {
            collectOutgoingCallsExpr(gpa, module, a.left, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, a.right, source, calls_map);
        },
        .call => |c| collectOutgoingCallsExpr(gpa, module, .{ .call = c.call }, source, calls_map),
        .decl => |d| {
            switch (d.decl) {
                .let => |l| {
                    if (l.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                .@"var" => |v| {
                    if (v.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                .@"const" => |cc| {
                    if (cc.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                else => {},
            }
        },
        else => {},
    }
}

fn collectOutgoingCallsExpr(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    expr: Ast.Expr,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Range)),
) void {
    switch (expr) {
        .call => |e| {
            if (e.func) |func| {
                switch (func) {
                    .ident => |id| {
                        // Only track user function calls (not builtins)
                        if (id.ref.isValid()) {
                            const sym = module.symbols.items[id.ref.index()];
                            if (sym.kind == .function) {
                                if (offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)))) |range| {
                                    const gop = calls_map.getOrPut(gpa, id.name) catch return;
                                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                                    gop.value_ptr.append(gpa, range) catch {};
                                }
                            }
                        }
                    },
                    else => {},
                }
                collectOutgoingCallsExpr(gpa, module, func, source, calls_map);
            }
            for (e.args.items) |arg| collectOutgoingCallsExpr(gpa, module, arg, source, calls_map);
        },
        .binary => |e| {
            collectOutgoingCallsExpr(gpa, module, e.left, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, e.right, source, calls_map);
        },
        .unary => |e| collectOutgoingCallsExpr(gpa, module, e.operand, source, calls_map),
        .index => |e| {
            collectOutgoingCallsExpr(gpa, module, e.base, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, e.idx, source, calls_map);
        },
        .paren => |e| collectOutgoingCallsExpr(gpa, module, e.expr, source, calls_map),
        .member => |e| collectOutgoingCallsExpr(gpa, module, e.base, source, calls_map),
        .ident, .literal => {},
    }
}

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
