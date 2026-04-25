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

const Handler = @This();

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
    \\{"textDocumentSync":{"openClose":true,"change":2,"save":{"includeText":false}},"positionEncoding":"utf-16","codeActionProvider":{"codeActionKinds":["quickfix"]},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"renameProvider":{"prepareProvider":true},"completionProvider":{"triggerCharacters":[".","@"]},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentSymbolProvider":true,"foldingRangeProvider":true,"typeDefinitionProvider":true,"inlayHintProvider":true,"codeLensProvider":{},"documentFormattingProvider":true,"semanticTokensProvider":{"full":true,"legend":{"tokenTypes":["keyword","function","struct","parameter","variable","number","type","comment","decorator"],"tokenModifiers":["declaration","readonly","defaultLibrary"]}},"selectionRangeProvider":true,"callHierarchyProvider":true,"documentHighlightProvider":true,"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false},"executeCommandProvider":{"commands":["wgslender.setMinifyMode","wgslender.toggleMinifyMode"]}}
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
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.source);
    }
    self.documents.deinit(self.gpa);
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
///     "inlayHints":     { "enabled": bool },
///     "diagnostics":    { "enabled": bool },
///     "minifyMode":     "off" | "insights" | "strict",
///     "minifyInsights": { "format": "delta"|"bytes"|"both",
///                         "functionSize": bool, "declSize": bool, "totalSize": bool },
///     "minifyLints":    { "enabled": bool }
///   }
pub fn applyClientSettings(self: *Handler, value: std.json.Value) void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
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
        .object => |o| if (o.get("enabled")) |b| switch (b) {
            .bool => |x| self.workspace_minify.lints_enabled = x,
            else => {},
        },
        else => {},
    };
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
};

/// Dispatch a `workspace/executeCommand` request. `args` matches the LSP
/// `ExecuteCommandParams.arguments` shape: `null` when the client sent no
/// arguments, otherwise a slice of `LSPAny` (= `std.json.Value`).
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
    return error.UnknownCommand;
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
// Diagnostics
// =========================================================================

/// Run wgslender validation and return LSP diagnostics.
/// Caller owns the returned slice — free with the same allocator.
pub fn validateDocument(self: *Handler, source: []const u8) ![]LspDiagnostic {
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);

    var result = try wgslender.validateWithOptions(self.gpa, source_z, .{});
    defer result.deinit(self.gpa);

    const entries = result.diagnostics.diagnostics.items;
    const diags = try self.gpa.alloc(LspDiagnostic, entries.len);

    for (entries, 0..) |entry, i| {
        diags[i] = convertDiagnostic(self.gpa, &entry);
    }

    return diags;
}

/// Validate a document using the analysis cache and append unused symbol warnings.
/// This is used by publishDiagnostics to produce a complete diagnostic set.
pub fn validateDocumentFull(self: *Handler, uri: []const u8) ![]LspDiagnostic {
    const analysis = try self.analyzeDocument(uri);

    const entries = analysis.diagnostics.diagnostics.items;
    var diags: std.ArrayListUnmanaged(LspDiagnostic) = .empty;
    errdefer {
        for (diags.items) |d| freeSingleDiagnostic(self.gpa, d);
        diags.deinit(self.gpa);
    }

    try diags.ensureTotalCapacity(self.gpa, entries.len + 8);
    for (entries) |entry| {
        try diags.append(self.gpa, convertDiagnostic(self.gpa, &entry));
    }

    // Append unused symbol warnings, dead code warnings, and unused binding warnings
    appendUnusedWarnings(self.gpa, analysis, &diags);
    appendDeadCodeWarnings(self.gpa, analysis, &diags);
    appendUnusedBindingWarnings(self.gpa, analysis, &diags);

    return try diags.toOwnedSlice(self.gpa);
}

fn freeSingleDiagnostic(gpa: std.mem.Allocator, d: LspDiagnostic) void {
    if (d.message.len > 0) gpa.free(d.message);
    if (d.spec_url.len > 0) gpa.free(d.spec_url);
    if (d.related.len > 0) {
        for (d.related) |r| {
            if (r.message.len > 0) gpa.free(r.message);
        }
        gpa.free(d.related);
    }
}

const wgsl_spec_base = "https://www.w3.org/TR/WGSL/#";

fn convertDiagnostic(gpa: std.mem.Allocator, entry: *const WgslDiagnostic.Entry) LspDiagnostic {
    var related: []const LspRelatedInfo = &.{};
    if (entry.related.len > 0) {
        if (gpa.alloc(LspRelatedInfo, entry.related.len)) |rel| {
            for (entry.related, 0..) |r, ri| {
                rel[ri] = .{
                    .range = .{
                        .start = .{
                            .line = if (r.range.start.line > 0) r.range.start.line - 1 else 0,
                            .character = if (r.range.start.column > 0) r.range.start.column - 1 else 0,
                        },
                        .end = .{
                            .line = if (r.range.end.line > 0) r.range.end.line - 1 else 0,
                            .character = if (r.range.end.column > 0) r.range.end.column - 1 else 0,
                        },
                    },
                    .message = gpa.dupe(u8, r.message) catch "",
                };
            }
            related = rel;
        } else |_| {}
    }
    return .{
        .range = .{
            .start = .{
                .line = if (entry.range.start.line > 0) entry.range.start.line - 1 else 0,
                .character = if (entry.range.start.column > 0) entry.range.start.column - 1 else 0,
            },
            .end = .{
                .line = if (entry.range.end.line > 0) entry.range.end.line - 1 else 0,
                .character = if (entry.range.end.column > 0) entry.range.end.column - 1 else 0,
            },
        },
        .severity = switch (entry.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .hint => .hint,
            .note => .information,
            else => .information,
        },
        .message = gpa.dupe(u8, entry.message) catch "",
        .code = entry.code,
        .spec_url = if (entry.code.len > 0 and entry.spec_ref.len > 0) blk: {
            const url = gpa.alloc(u8, wgsl_spec_base.len + entry.spec_ref.len) catch break :blk "";
            @memcpy(url[0..wgsl_spec_base.len], wgsl_spec_base);
            @memcpy(url[wgsl_spec_base.len..], entry.spec_ref);
            break :blk url;
        } else "",
        .related = related,
    };
}

// =========================================================================
// Code Actions
// =========================================================================

/// Extract the suggestion from a "did you mean 'X'?" diagnostic message.
/// Returns the suggested name, or null if the message doesn't contain one.
pub fn extractDidYouMean(message: []const u8) ?[]const u8 {
    const needle = "; did you mean '";
    const idx = std.mem.indexOf(u8, message, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, message, start, "'") orelse return null;
    if (start >= end) return null;
    return message[start..end];
}

/// Extract a type-mismatch pair ({actual, expected}) from a diagnostic message.
/// Handles the three validator message shapes:
///   "cannot assign 'A' to 'E'"
///   "cannot return 'A' from function expecting 'E'"
///   "argument N of 'fn' has type 'A', expected 'E'"
/// In all three, the expected type is the second quoted substring.
/// Returns null if the message does not contain at least two quoted tokens.
pub fn extractTypeMismatch(message: []const u8) ?struct { actual: []const u8, expected: []const u8 } {
    const a_open = std.mem.indexOfScalar(u8, message, '\'') orelse return null;
    const a_close = std.mem.indexOfScalarPos(u8, message, a_open + 1, '\'') orelse return null;
    const b_open = std.mem.indexOfScalarPos(u8, message, a_close + 1, '\'') orelse return null;
    const b_close = std.mem.indexOfScalarPos(u8, message, b_open + 1, '\'') orelse return null;
    if (a_open + 1 > a_close or b_open + 1 > b_close) return null;
    return .{
        .actual = message[a_open + 1 .. a_close],
        .expected = message[b_open + 1 .. b_close],
    };
}

/// Parse a WGSL numeric type name into a `(shape, scalar)` pair, or null if the
/// name is not a recognized scalar/short-vector/long-vector form.
///
///   "f32"       → .{ .shape = "", .scalar = "f32" }
///   "vec3f"     → .{ .shape = "vec3", .scalar = "f32" }
///   "vec3<f32>" → .{ .shape = "vec3", .scalar = "f32" }
///
/// Matrices, atomics, pointers, arrays, abstract types, and user structs return null.
fn parseCastableType(name: []const u8) ?struct { shape: []const u8, scalar: []const u8 } {
    const scalars = [_][]const u8{ "f32", "i32", "u32", "f16", "bool" };
    for (scalars) |s| {
        if (std.mem.eql(u8, name, s)) return .{ .shape = "", .scalar = s };
    }
    const sizes = [_][]const u8{ "vec2", "vec3", "vec4" };
    for (sizes) |size| {
        if (!std.mem.startsWith(u8, name, size)) continue;
        const tail = name[size.len..];
        // Short form: vec3f / vec3i / vec3u / vec3h
        if (tail.len == 1) {
            const scalar: []const u8 = switch (tail[0]) {
                'f' => "f32",
                'i' => "i32",
                'u' => "u32",
                'h' => "f16",
                else => return null,
            };
            return .{ .shape = size, .scalar = scalar };
        }
        // Long form: vec3<f32>
        if (tail.len >= 3 and tail[0] == '<' and tail[tail.len - 1] == '>') {
            const inner = tail[1 .. tail.len - 1];
            for (scalars) |s| {
                if (std.mem.eql(u8, inner, s)) return .{ .shape = size, .scalar = s };
            }
            return null;
        }
        return null;
    }
    return null;
}

/// Whitelist of WGSL type names that a quickfix may safely wrap an expression with
/// as a same-shape conversion constructor (e.g. `f32(x)`, `vec3f(v)`).
/// Rejects user-defined structs, abstract types, matrices, and shape-changing
/// targets (e.g. vec3 → vec4) where a plain constructor is not a valid conversion.
/// Accepts both short (`vec3f`) and long (`vec3<f32>`) spellings — the validator
/// emits the long form for vectors.
pub fn isSafeCastTarget(actual: []const u8, expected: []const u8) bool {
    const a = parseCastableType(actual) orelse return false;
    const e = parseCastableType(expected) orelse return false;
    return std.mem.eql(u8, a.shape, e.shape);
}

/// Extract the location number from a "duplicate input/output @location(N)" message.
/// Returns the numeric value N, or null if the message doesn't match.
pub fn extractDuplicateLocation(message: []const u8) ?i64 {
    // Look for "duplicate input @location(" or "duplicate output @location("
    const patterns = [_][]const u8{ "duplicate input @location(", "duplicate output @location(" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern)) |idx| {
            const start = idx + pattern.len;
            const end = std.mem.indexOfPos(u8, message, start, ")") orelse continue;
            if (start >= end) continue;
            return std.fmt.parseInt(i64, message[start..end], 10) catch continue;
        }
    }
    return null;
}

/// Compute code actions for the given diagnostics.
/// Caller owns the returned slice.
pub fn computeCodeActions(
    self: *Handler,
    diags: []const LspDiagnostic,
) ![]LspCodeAction {
    var actions: std.ArrayListUnmanaged(LspCodeAction) = .empty;

    for (diags) |diag| {
        // "Did you mean?" rename fix
        if (isDidYouMeanCode(diag.code)) {
            if (extractDidYouMean(diag.message)) |suggestion| {
                const title = std.fmt.allocPrint(self.gpa, "Replace with '{s}'", .{suggestion}) catch continue;
                const new_text = self.gpa.dupe(u8, suggestion) catch {
                    self.gpa.free(title);
                    continue;
                };
                const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                edit[0] = .{ .range = diag.range, .new_text = new_text };
                actions.append(self.gpa, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = true,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.gpa.free(edit);
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                };
            }
        }

        // Duplicate @location(N) → increment to N+1
        if (std.mem.eql(u8, diag.code, "E0602")) {
            if (extractDuplicateLocation(diag.message)) |loc_val| {
                const new_val = loc_val + 1;
                const title = std.fmt.allocPrint(self.gpa, "Change to @location({d})", .{new_val}) catch continue;
                const new_text = std.fmt.allocPrint(self.gpa, "@location({d})", .{new_val}) catch {
                    self.gpa.free(title);
                    continue;
                };
                // Find @location(...) within the source at the diagnostic range
                const attr_range = self.findLocationAttrRange(diag.range) orelse {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                edit[0] = .{ .range = attr_range, .new_text = new_text };
                actions.append(self.gpa, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = false,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.gpa.free(edit);
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                };
            }
        }

        // Vertex entry point missing @builtin(position) → either prepend the
        // attribute to the return type, or add a `@builtin(position)` member to
        // the return struct.
        if (std.mem.eql(u8, diag.code, "E0600") and
            std.mem.indexOf(u8, diag.message, "must include @builtin(position)") != null)
        {
            switch (self.findVertexReturnTarget(diag.range)) {
                .plain => |range| vertex_plain: {
                    const title = self.gpa.dupe(u8, "Add @builtin(position) to return type") catch break :vertex_plain;
                    const new_text = self.gpa.dupe(u8, "@builtin(position) ") catch {
                        self.gpa.free(title);
                        break :vertex_plain;
                    };
                    const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                        self.gpa.free(new_text);
                        self.gpa.free(title);
                        break :vertex_plain;
                    };
                    edit[0] = .{ .range = range, .new_text = new_text };
                    actions.append(self.gpa, .{
                        .title = title,
                        .kind = "quickfix",
                        .is_preferred = true,
                        .diagnostic = diag,
                        .edits = edit,
                    }) catch {
                        self.gpa.free(edit);
                        self.gpa.free(new_text);
                        self.gpa.free(title);
                    };
                },
                .struct_body => |sb| vertex_struct: {
                    const title = std.fmt.allocPrint(self.gpa, "Add @builtin(position) member to '{s}'", .{sb.name}) catch break :vertex_struct;
                    const new_text = self.gpa.dupe(u8, "@builtin(position) position: vec4f, ") catch {
                        self.gpa.free(title);
                        break :vertex_struct;
                    };
                    const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                        self.gpa.free(new_text);
                        self.gpa.free(title);
                        break :vertex_struct;
                    };
                    edit[0] = .{ .range = sb.insert_at, .new_text = new_text };
                    actions.append(self.gpa, .{
                        .title = title,
                        .kind = "quickfix",
                        .is_preferred = true,
                        .diagnostic = diag,
                        .edits = edit,
                    }) catch {
                        self.gpa.free(edit);
                        self.gpa.free(new_text);
                        self.gpa.free(title);
                    };
                },
                .none => {},
            }
        }

        // Type mismatch → wrap the expression with the expected type's constructor.
        // Only E0200 (assignment / return): its range reliably spans the offending
        // expression. E0203 is intentionally skipped for now — its range covers the
        // whole call expression, which would wrap the callee. Tracked as a followup.
        if (std.mem.eql(u8, diag.code, "E0200")) cast_block: {
            const tm = extractTypeMismatch(diag.message) orelse break :cast_block;
            if (!isSafeCastTarget(tm.actual, tm.expected)) break :cast_block;
            // Need the source text of the offending expression to wrap it.
            const source = blk: {
                var it = self.documents.iterator();
                while (it.next()) |entry| {
                    break :blk entry.value_ptr.source;
                }
                break :blk null;
            } orelse break :cast_block;
            const start_off = lspPositionToOffset(source, diag.range.start) orelse break :cast_block;
            const end_off = lspPositionToOffset(source, diag.range.end) orelse break :cast_block;
            if (end_off <= start_off) break :cast_block;
            const orig = source[start_off..end_off];

            const title = std.fmt.allocPrint(self.gpa, "Cast to '{s}'", .{tm.expected}) catch break :cast_block;
            const new_text = std.fmt.allocPrint(self.gpa, "{s}({s})", .{ tm.expected, orig }) catch {
                self.gpa.free(title);
                break :cast_block;
            };
            const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                self.gpa.free(new_text);
                self.gpa.free(title);
                break :cast_block;
            };
            edit[0] = .{ .range = diag.range, .new_text = new_text };
            actions.append(self.gpa, .{
                .title = title,
                .kind = "quickfix",
                .is_preferred = false,
                .diagnostic = diag,
                .edits = edit,
            }) catch {
                self.gpa.free(edit);
                self.gpa.free(new_text);
                self.gpa.free(title);
            };
        }

        // Unused symbol → remove entire declaration line, or rename with _ prefix
        if (std.mem.eql(u8, diag.code, "W0001")) {
            if (std.mem.indexOf(u8, diag.message, "'")) |start| {
                if (std.mem.indexOfPos(u8, diag.message, start + 1, "'")) |end| {
                    const name = diag.message[start + 1 .. end];
                    const title = std.fmt.allocPrint(self.gpa, "Remove unused '{s}'", .{name}) catch continue;
                    const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                        self.gpa.free(title);
                        continue;
                    };
                    // Delete from start of the line to start of next line
                    edit[0] = .{
                        .range = .{
                            .start = .{ .line = diag.range.start.line, .character = 0 },
                            .end = .{ .line = diag.range.start.line + 1, .character = 0 },
                        },
                        .new_text = self.gpa.dupe(u8, "") catch "",
                    };
                    actions.append(self.gpa, .{
                        .title = title,
                        .kind = "quickfix",
                        .diagnostic = diag,
                        .edits = edit,
                    }) catch {
                        self.gpa.free(edit);
                        self.gpa.free(title);
                    };

                    // Secondary action: rename to _name (keep the declaration, silence the lint).
                    // Skip when the name already starts with _ to avoid __name.
                    if (name.len > 0 and name[0] != '_') {
                        const rename_title = std.fmt.allocPrint(self.gpa, "Rename to '_{s}'", .{name}) catch continue;
                        const rename_new_text = std.fmt.allocPrint(self.gpa, "_{s}", .{name}) catch {
                            self.gpa.free(rename_title);
                            continue;
                        };
                        const rename_edit = self.gpa.alloc(LspTextEdit, 1) catch {
                            self.gpa.free(rename_new_text);
                            self.gpa.free(rename_title);
                            continue;
                        };
                        rename_edit[0] = .{ .range = diag.range, .new_text = rename_new_text };
                        actions.append(self.gpa, .{
                            .title = rename_title,
                            .kind = "quickfix",
                            .is_preferred = false,
                            .diagnostic = diag,
                            .edits = rename_edit,
                        }) catch {
                            self.gpa.free(rename_edit);
                            self.gpa.free(rename_new_text);
                            self.gpa.free(rename_title);
                        };
                    }
                }
            }
        }

        // Feature not enabled → insert 'enable f16;'
        if (std.mem.eql(u8, diag.code, "E0900")) {
            if (std.mem.indexOf(u8, diag.message, "f16") != null) {
                const title = self.gpa.dupe(u8, "Add 'enable f16;'") catch continue;
                const new_text = self.gpa.dupe(u8, "enable f16;\n") catch {
                    self.gpa.free(title);
                    continue;
                };
                const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                // Insert at top of file
                edit[0] = .{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .new_text = new_text,
                };
                actions.append(self.gpa, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = true,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.gpa.free(edit);
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                };
            }
        }
    }

    return actions.toOwnedSlice(self.gpa) catch &.{};
}

fn isDidYouMeanCode(code: []const u8) bool {
    // E0100 = undefined_symbol, E0200 = type_mismatch (unknown type),
    // E0204 = not_callable, E0206 = no_such_member, E0403 = invalid_builtin
    return std.mem.eql(u8, code, "E0100") or
        std.mem.eql(u8, code, "E0200") or
        std.mem.eql(u8, code, "E0204") or
        std.mem.eql(u8, code, "E0206") or
        std.mem.eql(u8, code, "E0403");
}

/// Result of locating where to insert `@builtin(position)` to fix an E0600
/// vertex-missing-position diagnostic.
pub const VertexReturnTarget = union(enum) {
    /// Non-struct return type: insert `@builtin(position) ` at this range
    /// (empty range immediately before the return-type tokens).
    plain: Range,
    /// Struct return type: insert a new `@builtin(position) position: vec4f,`
    /// member at `insert_at` (empty range just before the struct's closing `}`).
    struct_body: struct {
        name: []const u8,
        insert_at: Range,
    },
    /// Source isn't shaped as expected (no `->`, struct body unbalanced, etc.).
    /// Surface this as "no action" rather than produce a wrong edit.
    none,
};

/// Search the document source around a vertex-entry-point diagnostic to find where
/// `@builtin(position)` should be inserted. See `VertexReturnTarget` for the two
/// cases: plain return type or struct return type.
fn findVertexReturnTarget(self: *Handler, diag_range: Range) VertexReturnTarget {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        const name_start = lspPositionToOffset(source, diag_range.start) orelse continue;
        if (name_start >= source.len) continue;

        // Scan forward from the function name for `->`, bounded to avoid running
        // into the next top-level decl on malformed input.
        const window_end = @min(source.len, name_start + 512);
        const arrow_rel = std.mem.indexOf(u8, source[name_start..window_end], "->") orelse continue;
        var off = name_start + arrow_rel + 2;

        // Skip whitespace after `->`.
        while (off < source.len and (source[off] == ' ' or source[off] == '\t' or
            source[off] == '\n' or source[off] == '\r')) : (off += 1)
        {}
        if (off >= source.len) continue;

        // Read an identifier token. If what follows `->` starts with `@` (an
        // attribute like `@location(0) vec4f`), fall into the plain branch:
        // prepending `@builtin(position) ` to the attribute list is still a
        // reasonable best-effort fix.
        const id_start = off;
        while (off < source.len and isIdentChar(source[off])) : (off += 1) {}
        const id_end = off;
        if (id_end == id_start) {
            // Starts with `@` or something else — use the plain insertion point.
            return makePlainTarget(self.gpa, source, id_start) orelse .none;
        }
        const type_name = source[id_start..id_end];

        // Scalars and vectors take the plain branch; otherwise look for a struct
        // declaration matching the identifier.
        if (parseCastableType(type_name) != null) {
            return makePlainTarget(self.gpa, source, id_start) orelse .none;
        }

        if (findStructBodyInsertPoint(self.gpa, source, type_name)) |insert_at| {
            return .{ .struct_body = .{ .name = type_name, .insert_at = insert_at } };
        }
        // Fall through: unrecognized type name, no matching struct — best effort
        // is to prepend `@builtin(position) ` before the identifier.
        return makePlainTarget(self.gpa, source, id_start) orelse .none;
    }
    return .none;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn makePlainTarget(gpa: std.mem.Allocator, source: []const u8, offset: usize) ?VertexReturnTarget {
    var line_index = WgslDiagnostic.LineIndex.init(gpa, source) catch return null;
    defer line_index.deinit(gpa);
    const pos = line_index.byteOffsetToLineColumn(@intCast(offset));
    const range: Range = .{
        .start = .{ .line = pos.line, .character = pos.col },
        .end = .{ .line = pos.line, .character = pos.col },
    };
    return .{ .plain = range };
}

fn findStructBodyInsertPoint(gpa: std.mem.Allocator, source: []const u8, struct_name: []const u8) ?Range {
    // Scan source for `struct <name>` followed by `{`. Accept any whitespace or
    // attribute list between `struct` and the name (keep it simple: find each
    // occurrence of `struct` and check that the next identifier matches).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "struct")) |idx| {
        // Require a word boundary before (start-of-file or non-ident char).
        const ok_before = idx == 0 or !isIdentChar(source[idx - 1]);
        // And after: `struct` must be followed by whitespace (or EOF).
        const after = idx + "struct".len;
        const ok_after = after < source.len and !isIdentChar(source[after]);
        if (!ok_before or !ok_after) {
            i = idx + 1;
            continue;
        }
        var j = after;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t' or
            source[j] == '\n' or source[j] == '\r')) : (j += 1)
        {}
        const name_start = j;
        while (j < source.len and isIdentChar(source[j])) : (j += 1) {}
        const name_end = j;
        if (name_end == name_start or !std.mem.eql(u8, source[name_start..name_end], struct_name)) {
            i = idx + 1;
            continue;
        }
        // Find `{` after the name.
        while (j < source.len and source[j] != '{' and source[j] != ';') : (j += 1) {}
        if (j >= source.len or source[j] != '{') {
            i = idx + 1;
            continue;
        }
        const body_open = j;
        // Find the matching `}`. WGSL struct bodies don't contain other braces.
        const close_off = std.mem.indexOfScalarPos(u8, source, body_open + 1, '}') orelse return null;

        var line_index = WgslDiagnostic.LineIndex.init(gpa, source) catch return null;
        defer line_index.deinit(gpa);
        const pos = line_index.byteOffsetToLineColumn(@intCast(close_off));
        const range: Range = .{
            .start = .{ .line = pos.line, .character = pos.col },
            .end = .{ .line = pos.line, .character = pos.col },
        };
        return range;
    }
    return null;
}

/// Search the document source near a diagnostic range to find the actual
/// @location(N) attribute range, so the edit replaces the whole annotation.
fn findLocationAttrRange(self: *Handler, diag_range: Range) ?Range {
    // We need the source to scan for @location(...) near the diagnostic.
    // Iterate all open documents to find one containing this range.
    // (Code actions are always for the current document, so we check all.)
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        // Convert LSP 0-based line/col to byte offset in the source.
        if (lspPositionToOffset(source, diag_range.start)) |start_offset| {
            // Search backwards from the diagnostic start for @location(
            const search_start = if (start_offset > 30) start_offset - 30 else 0;
            const region = source[search_start..@min(source.len, start_offset + 50)];
            if (std.mem.indexOf(u8, region, "@location(")) |rel_idx| {
                const abs_start = search_start + rel_idx;
                // Find the closing )
                if (std.mem.indexOfPos(u8, source, abs_start, ")")) |close_paren| {
                    const abs_end = close_paren + 1; // include the )
                    // Convert back to LSP positions
                    var line_index = WgslDiagnostic.LineIndex.init(self.gpa, source) catch return null;
                    // LineIndex is 0-based; LSP is also 0-based
                    const s = line_index.byteOffsetToLineColumn(@intCast(abs_start));
                    const e = line_index.byteOffsetToLineColumn(@intCast(abs_end));
                    line_index.deinit(self.gpa);
                    return .{
                        .start = .{ .line = s.line, .character = s.col },
                        .end = .{ .line = e.line, .character = e.col },
                    };
                }
            }
        }
    }
    return null;
}

/// Convert an LSP 0-based line:character position to a byte offset in source.
/// Handles LF, CR, and CRLF line endings.
pub fn lspPositionToOffset(source: []const u8, pos: Position) ?usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < source.len) {
        if (source[i] == '\r') {
            line += 1;
            // Skip LF in CRLF pair
            if (i + 1 < source.len and source[i + 1] == '\n') {
                i += 1;
            }
        } else if (source[i] == '\n') {
            line += 1;
        }
        i += 1;
    }
    if (line != pos.line) return null;
    const offset = i + pos.character;
    if (offset > source.len) return null;
    return offset;
}

/// Convert a byte offset to an LSP 0-based Position.
/// Uses a simple linear scan (suitable for typical shader sizes).
pub fn offsetToLspPosition(source: []const u8, offset: u32) ?Position {
    if (offset > source.len) return null;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else if (source[i] == '\r') {
            line += 1;
            col = 0;
            if (i + 1 < offset and source[i + 1] == '\n') {
                i += 1; // skip LF in CRLF
            }
        } else {
            col += 1;
        }
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
// AST Node-at-Position Lookup
// =========================================================================

const Ast = wgslender.Ast;

pub const NodeAtPosition = union(enum) {
    /// An identifier expression referencing a symbol.
    ident: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// A member access expression (e.g., `s.field`).
    member_access: struct { member: []const u8, loc: u32, base: Ast.Expr },
    /// A declaration name (the identifier in fn/struct/var/const/let/alias).
    decl_name: struct { sym_idx: Ast.SymbolIndex, loc: u32 },
    /// A type reference (e.g., `f32`, `MyStruct` in a type annotation).
    type_ref: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// A binary operator expression (cursor on the operator token).
    binary_expr: struct { expr: Ast.Expr, loc: u32, op_len: u32 },
    /// No identifiable node at this position.
    none,
};

/// Find the AST node at a given byte offset in the source.
/// Walks declarations, statements, and expressions to find the
/// most specific node covering the offset.
pub fn findNodeAtOffset(module: *const Ast.Module, offset: u32) NodeAtPosition {
    for (module.declarations.items) |decl| {
        const result = findInDecl(module, decl, offset);
        if (result != .none) return result;
    }
    return .none;
}

fn findInDecl(module: *const Ast.Module, decl: Ast.Decl, offset: u32) NodeAtPosition {
    switch (decl) {
        .function => |f| {
            if (checkDeclName(module, f.name, offset)) |r| return r;
            for (f.parameters.items) |param| {
                if (checkDeclName(module, param.name, offset)) |r| return r;
                if (findInType(param.typ, offset)) |r| return r;
            }
            if (f.return_type) |rt| {
                if (findInType(rt, offset)) |r| return r;
            }
            if (f.body) |body| {
                if (findInCompound(module, body, offset)) |r| return r;
            }
        },
        .@"struct" => |s| {
            if (checkDeclName(module, s.name, offset)) |r| return r;
            for (s.members.items) |m| {
                if (checkDeclName(module, m.name, offset)) |r| return r;
                if (findInType(m.typ, offset)) |r| return r;
            }
        },
        .@"const" => |c| {
            if (checkDeclName(module, c.name, offset)) |r| return r;
            if (c.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (c.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .override => |o| {
            if (checkDeclName(module, o.name, offset)) |r| return r;
            if (o.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (o.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .@"var" => |v| {
            if (checkDeclName(module, v.name, offset)) |r| return r;
            if (v.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (v.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .let => |l| {
            if (checkDeclName(module, l.name, offset)) |r| return r;
            if (l.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (l.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .alias => |a| {
            if (checkDeclName(module, a.name, offset)) |r| return r;
            if (findInType(a.typ, offset)) |r| return r;
        },
        .const_assert => |ca| {
            if (findInExpr(ca.expr, offset)) |r| return r;
        },
    }
    return .none;
}

fn checkDeclName(module: *const Ast.Module, sym_idx: Ast.SymbolIndex, offset: u32) ?NodeAtPosition {
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
        return .{ .decl_name = .{ .sym_idx = sym_idx, .loc = sym.loc } };
    }
    return null;
}

fn findInType(typ: Ast.Type, offset: u32) ?NodeAtPosition {
    switch (typ) {
        .ident => |t| {
            if (offset >= t.loc and offset < t.loc + @as(u32, @intCast(t.name.len))) {
                return .{ .type_ref = .{ .name = t.name, .ref = t.ref, .loc = t.loc } };
            }
        },
        .vec => |t| {
            if (t.elem_type) |et| return findInType(et, offset);
        },
        .mat => |t| {
            if (t.elem_type) |et| return findInType(et, offset);
        },
        .array => |t| {
            if (t.elem_type) |et| {
                if (findInType(et, offset)) |r| return r;
            }
            if (t.size) |sz| {
                // size is an Expr, not a Type
                return findInExpr(sz, offset);
            }
        },
        .ptr => |t| return findInType(t.elem_type, offset),
        .atomic => |t| return findInType(t.elem_type, offset),
        .sampler, .texture => {},
    }
    return null;
}

fn findInCompound(module: *const Ast.Module, compound: *const Ast.CompoundStmt, offset: u32) ?NodeAtPosition {
    for (compound.stmts.items) |stmt| {
        if (findInStmt(module, stmt, offset)) |r| return r;
    }
    return null;
}

fn findInStmt(module: *const Ast.Module, stmt: Ast.Stmt, offset: u32) ?NodeAtPosition {
    switch (stmt) {
        .compound => |c| return findInCompound(module, c, offset),
        .@"return" => |r| {
            if (r.value) |v| return findInExpr(v, offset);
        },
        .@"if" => |i| {
            if (findInExpr(i.condition, offset)) |r| return r;
            if (findInCompound(module, i.body, offset)) |r| return r;
            if (i.else_branch) |eb| return findInStmt(module, eb, offset);
        },
        .@"switch" => |s| {
            if (findInExpr(s.expr, offset)) |r| return r;
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| {
                    if (findInExpr(sel, offset)) |r| return r;
                }
                if (findInCompound(module, case.body, offset)) |r| return r;
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| {
                if (findInStmt(module, init_s, offset)) |r| return r;
            }
            if (f.condition) |cond| {
                if (findInExpr(cond, offset)) |r| return r;
            }
            if (f.update) |upd| {
                if (findInStmt(module, upd, offset)) |r| return r;
            }
            return findInCompound(module, f.body, offset);
        },
        .@"while" => |w| {
            if (findInExpr(w.condition, offset)) |r| return r;
            return findInCompound(module, w.body, offset);
        },
        .loop => |l| {
            if (findInCompound(module, l.body, offset)) |r| return r;
            if (l.continuing) |cont| return findInCompound(module, cont, offset);
        },
        .assign => |a| {
            if (findInExpr(a.left, offset)) |r| return r;
            return findInExpr(a.right, offset);
        },
        .incr_decr => |i| return findInExpr(i.expr, offset),
        .call => |c| return findInExpr(.{ .call = c.call }, offset),
        .decl => |d| {
            const result = findInDecl(module, d.decl, offset);
            if (result != .none) return result;
        },
        .@"break" => {},
        .@"continue" => {},
        .discard => {},
        .break_if => |b| return findInExpr(b.condition, offset),
    }
    return null;
}

fn findInExpr(expr: Ast.Expr, offset: u32) ?NodeAtPosition {
    switch (expr) {
        .ident => |e| {
            if (offset >= e.loc and offset < e.loc + @as(u32, @intCast(e.name.len))) {
                return .{ .ident = .{ .name = e.name, .ref = e.ref, .loc = e.loc } };
            }
        },
        .member => |e| {
            // e.loc is the dot position; member name starts at dot + 1
            const member_loc = e.loc + 1;
            if (offset >= member_loc and offset < member_loc + @as(u32, @intCast(e.member_name.len))) {
                return .{ .member_access = .{ .member = e.member_name, .loc = member_loc, .base = e.base } };
            }
            return findInExpr(e.base, offset);
        },
        .call => |e| {
            if (e.func) |f| {
                if (findInExpr(f, offset)) |r| return r;
            }
            if (e.template_type) |tt| {
                if (findInType(tt, offset)) |r| return r;
            }
            for (e.args.items) |arg| {
                if (findInExpr(arg, offset)) |r| return r;
            }
        },
        .binary => |e| {
            if (findInExpr(e.left, offset)) |r| return r;
            // Check if cursor is on the operator token itself
            const op_str = e.op.string();
            const op_len: u32 = @intCast(op_str.len);
            if (offset >= e.loc and offset < e.loc + op_len) {
                return .{ .binary_expr = .{ .expr = expr, .loc = e.loc, .op_len = op_len } };
            }
            return findInExpr(e.right, offset);
        },
        .unary => |e| return findInExpr(e.operand, offset),
        .index => |e| {
            if (findInExpr(e.base, offset)) |r| return r;
            return findInExpr(e.idx, offset);
        },
        .paren => |e| return findInExpr(e.expr, offset),
        .literal => {},
    }
    return null;
}

// =========================================================================
// LSP Feature: Hover
// =========================================================================

pub const HoverResult = struct {
    contents: []const u8,
    range: Range,
};

pub const DocumentHighlight = struct {
    range: Range,
    kind: HighlightKind,
};

pub const HighlightKind = enum(u8) {
    text = 1,
    read = 2,
    write = 3,
};

pub fn computeHover(self: *Handler, uri: []const u8, position: Position) !?HoverResult {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    var buf: [1024]u8 = undefined;
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) {
                // Check if this is a builtin function name
                if (Builtins.lookup(id.name)) |builtin| {
                    const contents = try self.formatBuiltinHover(&buf, id.name, builtin);
                    return .{
                        .contents = contents,
                        .range = offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len))) orelse return null,
                    };
                }
                return null;
            }
            const sym = module.symbols.items[id.ref.index()];
            const kind_str = @tagName(sym.kind);
            const contents: []const u8 = blk: {
                if (analysis.symbol_types.get(id.ref.index())) |t| {
                    // For functions, show full signature
                    if (t == .function) {
                        if (formatFunctionSignature(&buf, module, id.ref, t.function)) |sig| {
                            break :blk try self.gpa.dupe(u8, sig);
                        }
                    }
                    const type_str = t.string();
                    // For consts, show value if known
                    if (sym.kind == .@"const") {
                        if (analysis.const_values.get(id.ref.index())) |val| {
                            const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s} = {d}", .{ kind_str, id.name, type_str, val }) catch return null).len;
                            break :blk try self.gpa.dupe(u8, buf[0..len]);
                        }
                    }
                    const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, id.name, type_str }) catch return null).len;
                    break :blk try self.gpa.dupe(u8, buf[0..len]);
                }
                const len = (std.fmt.bufPrint(&buf, "({s}) {s}: unknown", .{ kind_str, id.name }) catch return null).len;
                break :blk try self.gpa.dupe(u8, buf[0..len]);
            };
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len))) orelse return null,
            };
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            const kind_str = @tagName(sym.kind);
            const contents: []const u8 = blk: {
                if (analysis.symbol_types.get(dn.sym_idx.index())) |t| {
                    // For functions, show full signature
                    if (t == .function) {
                        if (formatFunctionSignature(&buf, module, dn.sym_idx, t.function)) |sig| {
                            break :blk try self.gpa.dupe(u8, sig);
                        }
                    }
                    const type_str = t.string();
                    // For consts, show value if known
                    if (sym.kind == .@"const") {
                        if (analysis.const_values.get(dn.sym_idx.index())) |val| {
                            const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s} = {d}", .{ kind_str, sym.original_name, type_str, val }) catch return null).len;
                            break :blk try self.gpa.dupe(u8, buf[0..len]);
                        }
                    }
                    const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, sym.original_name, type_str }) catch return null).len;
                    break :blk try self.gpa.dupe(u8, buf[0..len]);
                }
                const len = (std.fmt.bufPrint(&buf, "({s}) {s}", .{ kind_str, sym.original_name }) catch return null).len;
                break :blk try self.gpa.dupe(u8, buf[0..len]);
            };
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len))) orelse return null,
            };
        },
        .type_ref => |tr| {
            if (analysis.struct_types.get(tr.name)) |st| {
                const contents = try formatStructLayout(self.gpa, tr.name, st);
                return .{
                    .contents = contents,
                    .range = offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len))) orelse return null,
                };
            }
            return null;
        },
        .member_access => |ma| {
            // Try to resolve the base expression's type and show field type
            const contents: []const u8 = blk: {
                const base_sym_idx = resolveExprSymbol(ma.base) orelse break :blk try self.gpa.dupe(u8, ma.member);
                if (!base_sym_idx.isValid()) break :blk try self.gpa.dupe(u8, ma.member);
                const base_type = analysis.symbol_types.get(base_sym_idx.index()) orelse break :blk try self.gpa.dupe(u8, ma.member);
                // Dereference pointers/references to get the underlying type
                const resolved: wgslender.Types.Type = switch (base_type) {
                    .reference => |r| r.element,
                    .pointer => |p| p.element,
                    else => base_type,
                };
                switch (resolved) {
                    .@"struct" => |st| {
                        if (st.getField(ma.member)) |field| {
                            const len = (std.fmt.bufPrint(&buf, "(field) {s}: {s}", .{ ma.member, field.typ.string() }) catch break :blk try self.gpa.dupe(u8, ma.member)).len;
                            break :blk try self.gpa.dupe(u8, buf[0..len]);
                        }
                    },
                    .vector => |v| {
                        if (ma.member.len == 1) {
                            const len = (std.fmt.bufPrint(&buf, "(swizzle) {s}: {s}", .{ ma.member, v.element.string() }) catch break :blk try self.gpa.dupe(u8, ma.member)).len;
                            break :blk try self.gpa.dupe(u8, buf[0..len]);
                        }
                    },
                    else => {},
                }
                break :blk try self.gpa.dupe(u8, ma.member);
            };
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, ma.loc, ma.loc + @as(u32, @intCast(ma.member.len))) orelse return null,
            };
        },
        .binary_expr => |be| {
            // Show const-evaluated result and/or expression type
            var parts: [2][]const u8 = undefined;
            var part_count: usize = 0;

            // Try to show the type of the expression (key on operator loc)
            if (analysis.expr_types.get(be.loc)) |info| {
                const type_str = info.typ.string();
                const formatted = std.fmt.bufPrint(&buf, "**{s}**", .{type_str}) catch "";
                if (formatted.len > 0) {
                    parts[part_count] = try self.gpa.dupe(u8, formatted);
                    part_count += 1;
                }
            }

            // Try to show const-evaluated result
            if (resolveConstExpr(be.expr, &analysis.const_values)) |val| {
                var val_buf: [64]u8 = undefined;
                const val_str = std.fmt.bufPrint(&val_buf, "= {d}", .{val}) catch "";
                if (val_str.len > 0) {
                    parts[part_count] = try self.gpa.dupe(u8, val_str);
                    part_count += 1;
                }
            }

            if (part_count == 0) return null;

            // Join parts with newline
            if (part_count == 2) {
                const combined = try std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ parts[0], parts[1] });
                self.gpa.free(parts[0]);
                self.gpa.free(parts[1]);
                return .{
                    .contents = combined,
                    .range = offsetRangeToLspRange(source, be.loc, be.loc + be.op_len) orelse return null,
                };
            }
            return .{
                .contents = parts[0],
                .range = offsetRangeToLspRange(source, be.loc, be.loc + be.op_len) orelse return null,
            };
        },
        .none => return null,
    }
}

/// Resolve an expression to its underlying SymbolIndex (walks through parens and member bases).
fn resolveExprSymbol(expr: Ast.Expr) ?Ast.SymbolIndex {
    return switch (expr) {
        .ident => |e| e.ref,
        .paren => |e| resolveExprSymbol(e.expr),
        .index => |e| resolveExprSymbol(e.base),
        else => null,
    };
}

/// Format a function signature with parameter names and resolved types.
fn formatFunctionSignature(buf: *[1024]u8, module: *const Ast.Module, sym_idx: Ast.SymbolIndex, fn_type: *const wgslender.Types.Function) ?[]const u8 {
    // Find the FunctionDecl matching this symbol
    const func_decl = for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (f.name == sym_idx) break f;
            },
            else => {},
        }
    } else return null;

    const sym = module.symbols.items[sym_idx.index()];
    var pos: usize = 0;
    const header = std.fmt.bufPrint(buf, "fn {s}(", .{sym.original_name}) catch return null;
    pos = header.len;

    for (func_decl.parameters.items, 0..) |param, pi| {
        if (pi > 0) {
            const sep = std.fmt.bufPrint(buf[pos..], ", ", .{}) catch return null;
            pos += sep.len;
        }
        const p_name = module.symbols.items[param.name.index()].original_name;
        const p_type_str = if (pi < fn_type.parameters.len) fn_type.parameters[pi].string() else "?";
        const p = std.fmt.bufPrint(buf[pos..], "{s}: {s}", .{ p_name, p_type_str }) catch return null;
        pos += p.len;
    }

    if (fn_type.return_type) |rt| {
        const ret = std.fmt.bufPrint(buf[pos..], ") -> {s}", .{rt.string()}) catch return null;
        pos += ret.len;
    } else {
        const tail = std.fmt.bufPrint(buf[pos..], ")", .{}) catch return null;
        pos += tail.len;
    }
    return buf[0..pos];
}

/// Format a hover tooltip for a builtin function, with spec documentation.
fn formatBuiltinHover(self: *Handler, buf: *[1024]u8, name: []const u8, builtin: Builtins.Builtin) ![]const u8 {
    var pos: usize = 0;

    // Signature from doc table, or fallback to name
    if (Builtins.doc(name)) |d| {
        const sig = std.fmt.bufPrint(buf, "{s}", .{d.signature}) catch return try self.gpa.dupe(u8, name);
        pos = sig.len;

        // Type constraint
        if (d.type_constraint.len > 0) {
            const tc = std.fmt.bufPrint(buf[pos..], "\n  {s}", .{d.type_constraint}) catch return try self.gpa.dupe(u8, buf[0..pos]);
            pos += tc.len;
        }

        // Description
        const desc = std.fmt.bufPrint(buf[pos..], "\n\n{s}", .{d.description}) catch return try self.gpa.dupe(u8, buf[0..pos]);
        pos += desc.len;
    } else {
        const header = std.fmt.bufPrint(buf, "(builtin) {s}", .{name}) catch return try self.gpa.dupe(u8, name);
        pos = header.len;
    }

    // Metadata line: category + evaluation stage
    const kind_str = @tagName(builtin.kind);
    const stage_str: []const u8 = switch (builtin.stage) {
        .const_eval => "const-evaluable",
        .runtime => "runtime",
        .override => "override-evaluable",
    };
    const meta = std.fmt.bufPrint(buf[pos..], "\n\n({s}) {s}", .{ kind_str, stage_str }) catch return try self.gpa.dupe(u8, buf[0..pos]);
    pos += meta.len;

    // Uniformity warning
    if (builtin.requiresUniform()) {
        const warn = std.fmt.bufPrint(buf[pos..], " | requires uniform control flow", .{}) catch return try self.gpa.dupe(u8, buf[0..pos]);
        pos += warn.len;
    }

    return try self.gpa.dupe(u8, buf[0..pos]);
}

/// Format a struct type with per-field byte offsets, sizes, and padding gaps.
fn formatStructLayout(gpa: std.mem.Allocator, name: []const u8, st: *wgslender.Types.Struct) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var scratch: [256]u8 = undefined;

    // Header: struct Name (size: NB, align: MB)
    const header = std.fmt.bufPrint(&scratch, "struct {s} (size: {d}B, align: {d}B)", .{ name, st.size_bytes, st.align_bytes }) catch return try gpa.dupe(u8, name);
    try out.appendSlice(gpa, header);

    for (st.fields, 0..) |field, fi| {
        const field_size = field.typ.size();
        const field_align = field.typ.alignment();

        // Check for padding before this field
        if (fi > 0) {
            const prev = st.fields[fi - 1];
            const prev_end = prev.offset + prev.typ.size();
            if (field.offset > prev_end) {
                const padding = field.offset - prev_end;
                const pad_line = std.fmt.bufPrint(&scratch, "\n  @{d}  [{d}B padding]", .{ prev_end, padding }) catch continue;
                try out.appendSlice(gpa, pad_line);
            }
        }

        // Field line
        const fld_line = std.fmt.bufPrint(&scratch, "\n  @{d}  {s}: {s}  ({d}B, align {d})", .{ field.offset, field.name, field.typ.string(), field_size, field_align }) catch continue;
        try out.appendSlice(gpa, fld_line);
    }

    // Trailing padding
    if (st.fields.len > 0) {
        const last = st.fields[st.fields.len - 1];
        const last_end = last.offset + last.typ.size();
        if (st.size_bytes > last_end) {
            const trailing = st.size_bytes - last_end;
            const trail_line = std.fmt.bufPrint(&scratch, "\n  @{d}  [{d}B padding]", .{ last_end, trailing }) catch "";
            try out.appendSlice(gpa, trail_line);
        }
    }

    return try gpa.dupe(u8, out.items);
}

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
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            const sym = module.symbols.items[tr.ref.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .member_access, .binary_expr, .none => return null,
    }
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

    const MinifyEstimator = wgslender.MinifyEstimator;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const result = MinifyEstimator.estimate(arena.allocator(), @constCast(module), .{}) catch return;

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
};

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

    return try self.gpa.dupe(CodeLensInfo, lenses.items);
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
fn resolveConstExpr(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64)) ?i64 {
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

test "convertDiagnostic preserves code" {
    const entry = WgslDiagnostic.Entry{ .code = "E0200" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqualStrings("E0200", result.code);
}

test "convertDiagnostic builds spec_url from spec_ref" {
    const entry = WgslDiagnostic.Entry{ .code = "E0700", .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    defer std.testing.allocator.free(result.spec_url);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", result.spec_url);
}

test "convertDiagnostic omits code and spec_url when empty" {
    const entry = WgslDiagnostic.Entry{};
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.code.len);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

test "convertDiagnostic omits spec_url when code empty" {
    const entry = WgslDiagnostic.Entry{ .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

/// Frees all allocations within a diagnostics slice (messages, related info, the slice itself).
pub fn freeDiagnostics(gpa: std.mem.Allocator, diags: []LspDiagnostic) void {
    for (diags) |d| {
        if (d.related.len > 0) {
            for (d.related) |r| {
                if (r.message.len > 0) gpa.free(r.message);
            }
            gpa.free(d.related);
        }
        if (d.message.len > 0) gpa.free(d.message);
        if (d.spec_url.len > 0) gpa.free(d.spec_url);
    }
    gpa.free(diags);
}

/// Frees all allocations within a code actions slice (titles, edits, the slice itself).
pub fn freeCodeActions(gpa: std.mem.Allocator, actions: []LspCodeAction) void {
    for (actions) |a| {
        gpa.free(a.title);
        for (a.edits) |edit| {
            gpa.free(edit.new_text);
        }
        gpa.free(a.edits);
    }
    gpa.free(actions);
}

test "code round-trips through validateDocument" {
    // A type mismatch triggers a diagnostic with code "E0200".
    const source =
        \\const x: i32 = 1.5;
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    // Find a diagnostic with a code
    for (diags) |d| {
        if (d.code.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, d.code, "E"));
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with a code, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

test "spec_url round-trips through validateDocument" {
    // workgroupBarrier inside a branch on a non-uniform builtin triggers
    // a uniformity error with code (E0701) and spec_ref ("uniformity").
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
        \\  if (global_invocation_id.x > 0) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    for (diags) |d| {
        if (d.spec_url.len > 0) {
            try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", d.spec_url);
            try std.testing.expect(d.code.len > 0);
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with spec_url, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// Code Action Tests
// =========================================================================

test "extractDidYouMean: undefined identifier" {
    const result = extractDidYouMean("use of undeclared identifier 'pos'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: unknown type" {
    const result = extractDidYouMean("unknown type 'vec3'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: no such member" {
    const result = extractDidYouMean("struct 'Foo' has no member 'y'; did you mean 'x'?");
    try std.testing.expectEqualStrings("x", result.?);
}

test "extractDidYouMean: not callable" {
    const result = extractDidYouMean("'foo' is not a function or type constructor; did you mean 'foo2'?");
    try std.testing.expectEqualStrings("foo2", result.?);
}

test "extractDidYouMean: invalid builtin" {
    const result = extractDidYouMean("unknown @builtin value 'positon'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: no suggestion" {
    try std.testing.expect(extractDidYouMean("type mismatch: expected 'f32'") == null);
}

test "extractDidYouMean: empty message" {
    try std.testing.expect(extractDidYouMean("") == null);
}

test "extractDuplicateLocation: input" {
    try std.testing.expectEqual(@as(i64, 0), extractDuplicateLocation("duplicate input @location(0)").?);
}

test "extractDuplicateLocation: output" {
    try std.testing.expectEqual(@as(i64, 3), extractDuplicateLocation("duplicate output @location(3)").?);
}

test "extractDuplicateLocation: no match" {
    try std.testing.expect(extractDuplicateLocation("some other error") == null);
}

test "extractDuplicateLocation: empty" {
    try std.testing.expect(extractDuplicateLocation("") == null);
}

test "computeCodeActions: did-you-mean produces rename action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 8 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("quickfix", actions[0].kind);
    try std.testing.expect(actions[0].is_preferred);
    try std.testing.expectEqual(@as(usize, 1), actions[0].edits.len);
    try std.testing.expectEqualStrings("position", actions[0].edits[0].new_text);
    // Edit range matches diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 8), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: no suggestion means no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'zzzzz'",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: non-matching code produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "break statement must be inside loop",
        .code = "E0500",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: multiple diagnostics produce multiple actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
        },
        .{
            .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 4 } },
            .severity = .@"error",
            .message = "unknown type 'vec3'; did you mean 'vec3f'?",
            .code = "E0200",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Replace with 'vec3f'", actions[1].title);
}

test "computeCodeActions: E0206 no_such_member with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 11 } },
        .severity = .@"error",
        .message = "struct 'Foo' has no member 'y'; did you mean 'x'?",
        .code = "E0206",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'x'", actions[0].title);
    try std.testing.expectEqualStrings("x", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0403 invalid builtin with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 17 } },
        .severity = .@"error",
        .message = "unknown @builtin value 'positon'; did you mean 'position'?",
        .code = "E0403",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
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

test "extractDidYouMean: suggestion with underscores" {
    const result = extractDidYouMean("use of undeclared identifier 'global_id'; did you mean 'global_invocation_id'?");
    try std.testing.expectEqualStrings("global_invocation_id", result.?);
}

test "extractDidYouMean: suggestion with numbers" {
    const result = extractDidYouMean("unknown type 'vec3f32'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: single-character suggestion" {
    const result = extractDidYouMean("struct 'S' has no member 'ab'; did you mean 'a'?");
    try std.testing.expectEqualStrings("a", result.?);
}

test "extractDidYouMean: message with quotes but no suggestion" {
    // Has single quotes but not the "did you mean" pattern
    try std.testing.expect(extractDidYouMean("cannot initialize 'x' with type 'f32'") == null);
}

test "extractDuplicateLocation: multi-digit numbers" {
    try std.testing.expectEqual(@as(i64, 10), extractDuplicateLocation("duplicate input @location(10)").?);
    try std.testing.expectEqual(@as(i64, 99), extractDuplicateLocation("duplicate output @location(99)").?);
    try std.testing.expectEqual(@as(i64, 255), extractDuplicateLocation("duplicate input @location(255)").?);
}

test "extractDuplicateLocation: non-numeric content" {
    // @location with non-numeric value should return null
    try std.testing.expect(extractDuplicateLocation("duplicate input @location(abc)") == null);
}

test "computeCodeActions: E0204 not_callable with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
        .severity = .@"error",
        .message = "'foo' is not a function or type constructor; did you mean 'f32'?",
        .code = "E0204",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'f32'", actions[0].title);
    try std.testing.expectEqualStrings("f32", actions[0].edits[0].new_text);
}

test "computeCodeActions: empty diagnostic array" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{};
    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty code" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "some error; did you mean 'x'?",
        .code = "",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty code should not match any handler
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty message" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty message means no suggestion extractable
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: zero-width diagnostic range" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'x'; did you mean 'y'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Still produces action even with zero-width range (insertion)
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("y", actions[0].edits[0].new_text);
    // Edit range matches the zero-width diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: E0602 duplicate location increment" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // Register a source document so findLocationAttrRange can scan it
    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[0].title);
    try std.testing.expectEqualStrings("@location(1)", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0602 with no open document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // No document opened — findLocationAttrRange should return null
    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 10 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // No action because no document to scan
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: E0602 multi-digit location" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(10) a: f32, @location(10) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 22 }, .end = .{ .line = 0, .character = 36 } },
        .severity = .@"error",
        .message = "duplicate input @location(10)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(11)", actions[0].title);
    try std.testing.expectEqualStrings("@location(11)", actions[0].edits[0].new_text);
}

test "computeCodeActions: mixed diagnostics produce correct actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
            .severity = .@"error",
            .message = "duplicate input @location(0)",
            .code = "E0602",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
            .severity = .@"error",
            .message = "break statement must be inside loop",
            .code = "E0500",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // E0100 produces rename, E0602 produces location fix, E0500 produces nothing
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[1].title);
}

test "isDidYouMeanCode: all supported codes" {
    try std.testing.expect(isDidYouMeanCode("E0100"));
    try std.testing.expect(isDidYouMeanCode("E0200"));
    try std.testing.expect(isDidYouMeanCode("E0204"));
    try std.testing.expect(isDidYouMeanCode("E0206"));
    try std.testing.expect(isDidYouMeanCode("E0403"));
}

test "isDidYouMeanCode: non-matching codes" {
    try std.testing.expect(!isDidYouMeanCode("E0500"));
    try std.testing.expect(!isDidYouMeanCode("E0602"));
    try std.testing.expect(!isDidYouMeanCode(""));
    try std.testing.expect(!isDidYouMeanCode("E0101"));
}

test "convertDiagnostic OOM on message dupe yields empty message" {
    // FailingAllocator that fails on the first allocation (the message dupe).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    const entry = WgslDiagnostic.Entry{ .message = "some error" };
    const result = convertDiagnostic(alloc, &entry);

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
    const result = convertDiagnostic(alloc, &entry);

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
    const result = convertDiagnostic(std.testing.allocator, &entry);

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
