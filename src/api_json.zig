//! Shared JSON-producing layer between the C-ABI shell (`src/lib.zig`) and
//! the WASM shell (`src/wasm.zig`). Each function here takes an allocator
//! plus already-decoded slices and returns either a flat `[]u8` JSON blob
//! or a small result struct for multi-part outputs. Allocator.Error is the
//! only error returned: per-operation failures (parse error, missing
//! symbol, etc.) collapse to a structured JSON payload that the caller
//! returns verbatim.
//!
//! Both shells wrap a call into one `ArenaAllocator.init(<base>)` /
//! `defer arena.deinit()` per request, so this layer can leak intermediates
//! into the supplied allocator with no manual frees.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wgslender = @import("root.zig");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Minifier = @import("Minifier.zig");
const Validator = @import("Validator.zig");
const Reflect = @import("Reflect.zig");
const Diagnostic = @import("Diagnostic.zig");
const Config = @import("Config.zig");
const Compiler = @import("Compiler.zig");
const Edits = @import("Edits.zig");
const StableId = @import("StableId.zig");
const Linter = @import("lint/Linter.zig");

// =========================================================================
// Result types for multi-part outputs
// =========================================================================

pub const ValidateResult = struct {
    valid: bool,
    error_count: u32,
    warning_count: u32,
    json: []u8,
};

pub const LintResult = struct {
    error_count: u32,
    warning_count: u32,
    json: []u8,
};

pub const LintFixResult = struct {
    fixed: []u8,
    error_count: u32,
    warning_count: u32,
    json: []u8,
};

pub const CompileResult = struct {
    wasm: []u8,
    original_size: u32,
    errors_json: []u8,
};

// =========================================================================
// Helpers
// =========================================================================

/// Make a sentinel-terminated copy of `raw` so the parser can consume it.
pub fn makeSentinelSource(alloc: Allocator, raw: []const u8) Allocator.Error![:0]u8 {
    const buf = try alloc.alloc(u8, raw.len + 1);
    @memcpy(buf[0..raw.len], raw);
    buf[raw.len] = 0;
    return buf[0..raw.len :0];
}

/// `[]u8` clone of a comptime literal so callers can return a uniform type.
fn dupeLiteral(alloc: Allocator, comptime literal: []const u8) Allocator.Error![]u8 {
    return alloc.dupe(u8, literal);
}

fn finalize(buf: std.ArrayList(u8)) []u8 {
    return buf.items;
}

fn analyzeOrNull(alloc: Allocator, source: [:0]const u8) Allocator.Error!Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(alloc, source, .{});
}

// =========================================================================
// Minify
// =========================================================================

/// Flags-based minify. Returns the minified text bytes (no envelope).
pub fn minifyFlagsToBytes(
    alloc: Allocator,
    source: [:0]const u8,
    options: Minifier.Options,
) Allocator.Error![]u8 {
    const result = Minifier.minify(alloc, source, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return alloc.dupe(u8, result.code);
}

/// JSON-options minify. Returns the full
/// `{"code":"...","errors":[...],"originalSize":N,"minifiedSize":N,"sourceMap":...}`
/// envelope. On OOM, propagates; on minification failure, returns the
/// canonical error envelope.
pub fn minifyJsonToJson(
    alloc: Allocator,
    source: [:0]const u8,
    opts_json: []const u8,
) Allocator.Error![]u8 {
    const config = Config.parseJson(alloc, opts_json) catch Config{};
    var options = config.toOptions();
    if (config.source_map) |sm| options.generate_source_map = sm;
    if (config.source_map_sources) |sms| options.source_map_options.include_source = sms;

    const result = Minifier.minify(alloc, source, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"code\":\"");
    try Diagnostic.appendJsonEscaped(&buf, alloc, result.code);
    try buf.appendSlice(alloc, "\",\"errors\":[");
    for (result.errors, 0..) |err, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"message\":\"");
        try Diagnostic.appendJsonEscaped(&buf, alloc, err.message);
        try buf.appendSlice(alloc, "\"}");
    }
    try buf.appendSlice(alloc, "],\"originalSize\":");
    try Diagnostic.appendInt(&buf, alloc, result.original_size);
    try buf.appendSlice(alloc, ",\"minifiedSize\":");
    try Diagnostic.appendInt(&buf, alloc, result.minified_size);
    if (result.source_map) |sm| {
        try buf.appendSlice(alloc, ",\"sourceMap\":");
        try sm.toJson(&buf, alloc);
    }
    try buf.append(alloc, '}');
    return finalize(buf);
}

/// Combined minify+reflect. Returns `{"minify":{...},"reflect":{...}}`.
pub fn minifyAndReflectJsonToJson(
    alloc: Allocator,
    source: [:0]const u8,
    opts_json: []const u8,
) Allocator.Error![]u8 {
    const config = Config.parseJson(alloc, opts_json) catch Config{};
    var options = config.toOptions();
    if (config.source_map) |sm| options.generate_source_map = sm;
    if (config.source_map_sources) |sms| options.source_map_options.include_source = sms;

    const empty_result_json =
        "{\"minify\":{\"code\":\"\",\"errors\":[{\"message\":\"minification failed\"}]," ++
        "\"originalSize\":0,\"minifiedSize\":0}," ++
        "\"reflect\":{\"bindings\":[],\"structs\":{},\"entryPoints\":[]}}";

    const result = Minifier.minifyAndReflect(alloc, source, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(alloc, "{\"minify\":{\"code\":\"");
    try Diagnostic.appendJsonEscaped(&buf, alloc, result.minify.code);
    try buf.appendSlice(alloc, "\",\"errors\":[");
    for (result.minify.errors, 0..) |err, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"message\":\"");
        try Diagnostic.appendJsonEscaped(&buf, alloc, err.message);
        try buf.appendSlice(alloc, "\"}");
    }
    try buf.appendSlice(alloc, "],\"originalSize\":");
    try Diagnostic.appendInt(&buf, alloc, result.minify.original_size);
    try buf.appendSlice(alloc, ",\"minifiedSize\":");
    try Diagnostic.appendInt(&buf, alloc, result.minify.minified_size);
    if (result.minify.source_map) |sm| {
        try buf.appendSlice(alloc, ",\"sourceMap\":");
        try sm.toJson(&buf, alloc);
    }
    try buf.appendSlice(alloc, "},\"reflect\":");
    try result.reflect.toJson(&buf, alloc);
    try buf.append(alloc, '}');

    _ = empty_result_json; // reserved for a future propagated-error path
    return finalize(buf);
}

// =========================================================================
// Validate
// =========================================================================

fn writeDiagnosticsBare(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    entries: []const Diagnostic.Entry,
) Allocator.Error!void {
    try buf.append(alloc, '[');
    for (entries, 0..) |*entry, i| {
        if (i > 0) try buf.append(alloc, ',');
        try Diagnostic.entryToJson(buf, alloc, entry);
    }
    try buf.append(alloc, ']');
}

/// Append the canonical validate envelope
/// `{"valid":<bool>,"diagnostics":[...],"errorCount":N,"warningCount":N}` to
/// `buf`. Single source of truth for the shape, shared by the WASM/C-ABI
/// `validateToJson` and the CLI's `emitValidateJson`. No trailing newline —
/// the WASM surface stays newline-free; the CLI appends its own `\n`.
///
/// `valid` is passed explicitly (not read off a result) so each caller can
/// supply its own notion: the WASM path passes raw `result.valid`, while the
/// CLI's `--strict` mode passes a validity that also fails on warnings.
pub fn writeValidateEnvelope(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    valid: bool,
    entries: []const Diagnostic.Entry,
    error_count: u32,
    warning_count: u32,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"valid\":");
    try buf.appendSlice(alloc, if (valid) "true" else "false");
    try buf.appendSlice(alloc, ",\"diagnostics\":");
    try writeDiagnosticsBare(buf, alloc, entries);
    try buf.appendSlice(alloc, ",\"errorCount\":");
    try Diagnostic.appendInt(buf, alloc, error_count);
    try buf.appendSlice(alloc, ",\"warningCount\":");
    try Diagnostic.appendInt(buf, alloc, warning_count);
    try buf.append(alloc, '}');
}

/// Validate WGSL source. Returns a wrapped-object envelope
/// `{"valid":...,"diagnostics":[...],"errorCount":N,"warningCount":N}` plus
/// authoritative severity-typed counts on the result struct. Both the C-ABI
/// and WASM surfaces consume this same shape.
pub fn validateToJson(
    alloc: Allocator,
    source: [:0]const u8,
    strict: bool,
) Allocator.Error!ValidateResult {
    const result = wgslender.validateWithOptions(alloc, source, .{ .strict_mode = strict }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const error_count = result.diagnostics.errorCount();
    const warning_count = result.diagnostics.warningCount();

    var buf: std.ArrayList(u8) = .empty;
    try writeValidateEnvelope(&buf, alloc, result.valid, result.diagnostics.diagnostics.items, error_count, warning_count);

    return .{
        .valid = result.valid,
        .error_count = error_count,
        .warning_count = warning_count,
        .json = finalize(buf),
    };
}

// =========================================================================
// Reflect
// =========================================================================

/// Reflect WGSL source. On parse failure returns the canonical
/// `{"bindings":[],"structs":{},"entryPoints":[],"errors":[...]}` envelope.
pub fn reflectToJson(alloc: Allocator, source: [:0]const u8) Allocator.Error![]u8 {
    var result = wgslender.reflect(alloc, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    var buf: std.ArrayList(u8) = .empty;
    try result.toJson(&buf, alloc);
    return finalize(buf);
}

// =========================================================================
// Edits — find references / rename / rename-and-apply
// =========================================================================

fn writeEdit(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    edit: Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"start\":");
    try Diagnostic.appendInt(buf, alloc, edit.start);
    try buf.appendSlice(alloc, ",\"end\":");
    try Diagnostic.appendInt(buf, alloc, edit.end);
    try buf.appendSlice(alloc, ",\"newText\":\"");
    try Diagnostic.appendJsonEscaped(buf, alloc, new_text);
    try buf.appendSlice(alloc, "\"}");
}

fn writeEditsArray(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    edits: []const Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error!void {
    try buf.append(alloc, '[');
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(alloc, ',');
        try writeEdit(buf, alloc, e, new_text);
    }
    try buf.append(alloc, ']');
}

fn editsEnvelopeJson(
    alloc: Allocator,
    edits: []const Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"edits\":");
    try writeEditsArray(&buf, alloc, edits, new_text);
    try buf.append(alloc, '}');
    return finalize(buf);
}

fn renameApplySuccessJson(
    alloc: Allocator,
    rewritten: []const u8,
    edits: []const Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"ok\":true,\"source\":\"");
    try Diagnostic.appendJsonEscaped(&buf, alloc, rewritten);
    try buf.appendSlice(alloc, "\",\"edits\":");
    try writeEditsArray(&buf, alloc, edits, new_text);
    try buf.append(alloc, '}');
    return finalize(buf);
}

fn renameApplyFailureJson(
    alloc: Allocator,
    original: []const u8,
    msg: []const u8,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"ok\":false,\"source\":\"");
    try Diagnostic.appendJsonEscaped(&buf, alloc, original);
    try buf.appendSlice(alloc, "\",\"edits\":[],\"error\":\"");
    try Diagnostic.appendJsonEscaped(&buf, alloc, msg);
    try buf.appendSlice(alloc, "\"}");
    return finalize(buf);
}

pub fn findReferencesToJson(
    alloc: Allocator,
    source: [:0]const u8,
    offset: u32,
    include_declaration: bool,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"references\":[],\"error\":\"parse error\"}");

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return dupeLiteral(alloc, "{\"references\":[]}");

    const refs = try Edits.findReferences(alloc, module, target, include_declaration);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"references\":[");
    for (refs, 0..) |r, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"start\":");
        try Diagnostic.appendInt(&buf, alloc, r.start);
        try buf.appendSlice(alloc, ",\"end\":");
        try Diagnostic.appendInt(&buf, alloc, r.end);
        try buf.appendSlice(alloc, ",\"isWrite\":");
        try buf.appendSlice(alloc, if (r.is_write) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return finalize(buf);
}

pub fn renameToJson(
    alloc: Allocator,
    source: [:0]const u8,
    offset: u32,
    new_name: []const u8,
) Allocator.Error![]u8 {
    if (!Edits.isValidWgslIdentifier(new_name))
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"invalid identifier\"}");

    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"parse error\"}");

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"symbol not found\"}");

    const edits = (try Edits.renameEdits(alloc, module, target, new_name)) orelse
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"invalid identifier\"}");

    return editsEnvelopeJson(alloc, edits, new_name);
}

/// Same as renameToJson but parses against a sentinel-copy of `original`
/// and applies edits against the raw bytes. Caller supplies both.
pub fn renameApplyToJson(
    alloc: Allocator,
    source_sentinel: [:0]const u8,
    original: []const u8,
    offset: u32,
    new_name: []const u8,
) Allocator.Error![]u8 {
    if (!Edits.isValidWgslIdentifier(new_name))
        return renameApplyFailureJson(alloc, original, "invalid identifier");

    const analysis = try analyzeOrNull(alloc, source_sentinel);
    const module = analysis.module orelse return renameApplyFailureJson(alloc, original, "parse error");

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return renameApplyFailureJson(alloc, original, "symbol not found");

    const edits = (try Edits.renameEdits(alloc, module, target, new_name)) orelse
        return renameApplyFailureJson(alloc, original, "invalid identifier");

    const rewritten = try Edits.applyEdits(alloc, original, edits);
    return renameApplySuccessJson(alloc, rewritten, edits, new_name);
}

// =========================================================================
// Stable IDs
// =========================================================================

pub fn stableIdAtOffsetToJson(
    alloc: Allocator,
    source: [:0]const u8,
    offset: u32,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"stableId\":null,\"error\":\"parse error\"}");

    const maybe_id = StableId.stableIdAtOffset(alloc, module, offset) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IdTooLong => return dupeLiteral(alloc, "{\"stableId\":null,\"error\":\"id too long\"}"),
    };
    if (maybe_id) |id| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(alloc, "{\"stableId\":\"");
        try Diagnostic.appendJsonEscaped(&buf, alloc, id.bytes);
        try buf.appendSlice(alloc, "\"}");
        return finalize(buf);
    }
    return dupeLiteral(alloc, "{\"stableId\":null}");
}

fn rangeJson(alloc: Allocator, range: StableId.Range) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"start\":");
    try Diagnostic.appendInt(&buf, alloc, range.start);
    try buf.appendSlice(alloc, ",\"end\":");
    try Diagnostic.appendInt(&buf, alloc, range.end);
    try buf.append(alloc, '}');
    return finalize(buf);
}

pub fn locateStableIdToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"parse error\"}");

    if (StableId.locateStableId(module, id_bytes)) |range|
        return rangeJson(alloc, range);
    return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

pub fn locateDeclarationToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"parse error\"}");

    if (StableId.locateDeclaration(module, id_bytes)) |range|
        return rangeJson(alloc, range);
    return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

pub fn locateTypeToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"parse error\"}");

    if (StableId.locateType(module, id_bytes)) |range|
        return rangeJson(alloc, range);
    return dupeLiteral(alloc, "{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

pub fn renameByIdToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
    new_name: []const u8,
) Allocator.Error![]u8 {
    if (!Edits.isValidWgslIdentifier(new_name))
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"invalid identifier\"}");

    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"parse error\"}");

    const target = StableId.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"symbol not found\"}");

    const edits = (try Edits.renameEdits(alloc, module, target, new_name)) orelse
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"invalid identifier\"}");

    return editsEnvelopeJson(alloc, edits, new_name);
}

pub fn removeDeclarationByIdToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"parse error\"}");

    const target = StableId.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"symbol not found\"}");

    const edits = (try Edits.removeDeclarationEdit(alloc, module, target)) orelse
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"not a removable declaration\"}");

    return editsEnvelopeJson(alloc, edits, "");
}

pub fn removeDeclarationApplyByIdToJson(
    alloc: Allocator,
    source_sentinel: [:0]const u8,
    original: []const u8,
    id_bytes: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source_sentinel);
    const module = analysis.module orelse return renameApplyFailureJson(alloc, original, "parse error");

    const target = StableId.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return renameApplyFailureJson(alloc, original, "symbol not found");

    const edits = (try Edits.removeDeclarationEdit(alloc, module, target)) orelse
        return renameApplyFailureJson(alloc, original, "not a removable declaration");

    const rewritten = try Edits.applyEdits(alloc, original, edits);
    return renameApplySuccessJson(alloc, rewritten, edits, "");
}

pub fn changeTypeByIdToJson(
    alloc: Allocator,
    source: [:0]const u8,
    id_bytes: []const u8,
    new_type: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source);
    const module = analysis.module orelse return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"parse error\"}");

    const target = StableId.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"symbol not found\"}");

    const edits = (try Edits.changeTypeEdit(alloc, module, target, new_type)) orelse
        return dupeLiteral(alloc, "{\"edits\":[],\"error\":\"no type annotation or invalid replacement\"}");

    return editsEnvelopeJson(alloc, edits, new_type);
}

pub fn changeTypeApplyByIdToJson(
    alloc: Allocator,
    source_sentinel: [:0]const u8,
    original: []const u8,
    id_bytes: []const u8,
    new_type: []const u8,
) Allocator.Error![]u8 {
    const analysis = try analyzeOrNull(alloc, source_sentinel);
    const module = analysis.module orelse return renameApplyFailureJson(alloc, original, "parse error");

    const target = StableId.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return renameApplyFailureJson(alloc, original, "symbol not found");

    const edits = (try Edits.changeTypeEdit(alloc, module, target, new_type)) orelse
        return renameApplyFailureJson(alloc, original, "no type annotation or invalid replacement");

    const rewritten = try Edits.applyEdits(alloc, original, edits);
    return renameApplySuccessJson(alloc, rewritten, edits, new_type);
}

// =========================================================================
// Lint
// =========================================================================

/// Parse the JSON config payload into `Linter.Options`. Empty or
/// malformed payload degrades to defaults (zero rules enabled) rather
/// than failing.
///
/// Thin shim over `Config.parseJson` — the single source of truth for
/// the JSON shape. The returned `Options.extends` and `Options.rules`
/// alias slices owned by `alloc`; Linter consumers must keep `alloc`
/// alive for the duration of the lint run. Per-rule options
/// (`["warn", { ... }]`) thread through automatically because the same
/// parser path is used.
pub fn parseLintConfig(
    alloc: Allocator,
    config_bytes: []const u8,
) Allocator.Error!Linter.Options {
    if (config_bytes.len == 0) return .{};
    const config = Config.parseJson(alloc, config_bytes) catch return .{};
    return .{
        .extends = config.lint_extends,
        .rules = config.lint_rules,
        .report_unused_disable_directives = config.report_unused_disable_directives orelse false,
    };
}

/// Append the canonical per-file lint result object
/// `{"filePath":"...","diagnostics":[...],"errorCount":N,"warningCount":N,"fixableCount":N}`
/// to `buf`. Single source of truth for the lint JSON shape, shared by the
/// WASM/C-ABI lint surfaces (`file_path == null` ⇒ no `filePath` key) and the
/// CLI's ESLint-style `emitJson` (passes the input path and wraps this object
/// in a `{"results":[...]}` envelope). `entries` are the already-merged
/// analysis + lint diagnostics; the three counts are passed explicitly because
/// the CLI's `--quiet` filter can drop entries from the array while the counts
/// must stay authoritative over the unfiltered run.
pub fn writeLintFileResult(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    file_path: ?[]const u8,
    entries: []const Diagnostic.Entry,
    error_count: u32,
    warning_count: u32,
    fixable_count: u32,
) Allocator.Error!void {
    try buf.append(alloc, '{');
    if (file_path) |fp| {
        try buf.appendSlice(alloc, "\"filePath\":\"");
        try Diagnostic.appendJsonEscaped(buf, alloc, fp);
        try buf.appendSlice(alloc, "\",");
    }
    try buf.appendSlice(alloc, "\"diagnostics\":");
    try writeDiagnosticsBare(buf, alloc, entries);
    try buf.appendSlice(alloc, ",\"errorCount\":");
    try Diagnostic.appendInt(buf, alloc, error_count);
    try buf.appendSlice(alloc, ",\"warningCount\":");
    try Diagnostic.appendInt(buf, alloc, warning_count);
    try buf.appendSlice(alloc, ",\"fixableCount\":");
    try Diagnostic.appendInt(buf, alloc, fixable_count);
    try buf.append(alloc, '}');
}

/// Merge a lint run's analysis (parser/validator) diagnostics with its lint
/// diagnostics into one flat slice, analysis first — the order the CLI and the
/// old bare-array writer both used.
fn mergeLintEntries(
    alloc: Allocator,
    result: *const wgslender.LintResult,
) Allocator.Error![]const Diagnostic.Entry {
    var merged: std.ArrayList(Diagnostic.Entry) = .empty;
    for (result.analysis.diagnostics.items()) |d| try merged.append(alloc, d);
    for (result.lint.diagnostics.items()) |d| try merged.append(alloc, d);
    return merged.items;
}

pub fn lintToResult(
    alloc: Allocator,
    source: [:0]const u8,
    options: Linter.Options,
) Allocator.Error!LintResult {
    var result = wgslender.lint(alloc, source, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const entries = try mergeLintEntries(alloc, &result);
    const error_count = result.analysis.diagnostics.errorCount() + result.lint.error_count;

    var buf: std.ArrayList(u8) = .empty;
    try writeLintFileResult(&buf, alloc, null, entries, error_count, result.lint.warning_count, result.lint.fixable_count);

    return .{
        .error_count = error_count,
        .warning_count = result.lint.warning_count,
        .json = finalize(buf),
    };
}

pub fn lintFixToResult(
    alloc: Allocator,
    source: [:0]const u8,
    options: Linter.Options,
) Allocator.Error!LintFixResult {
    var result = wgslender.lint(alloc, source, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const fix_result = try Linter.Fixer.apply(
        alloc,
        source,
        result.lint.diagnostics.items(),
    );

    const entries = try mergeLintEntries(alloc, &result);
    const error_count = result.analysis.diagnostics.errorCount() + result.lint.error_count;

    var buf: std.ArrayList(u8) = .empty;
    try writeLintFileResult(&buf, alloc, null, entries, error_count, result.lint.warning_count, result.lint.fixable_count);

    return .{
        .fixed = try alloc.dupe(u8, fix_result.fixed),
        .error_count = error_count,
        .warning_count = result.lint.warning_count,
        .json = finalize(buf),
    };
}

// =========================================================================
// Compile
// =========================================================================

pub fn compileToResult(
    alloc: Allocator,
    source: [:0]const u8,
    opts_json: []const u8,
) Allocator.Error!CompileResult {
    const config = Config.parseJson(alloc, opts_json) catch Config{};
    const minify_options = config.toOptions();

    // Syntax errors are surfaced as diagnostics on the result (empty wasm);
    // only a real OOM propagates, matching every other function in this layer.
    const result = Compiler.compile(alloc, source, .{
        .minify = true,
        .minify_options = minify_options,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Serialize parse errors through the same entry serializer as validate, so
    // compile diagnostics carry positions/codes and share one wire shape.
    var buf: std.ArrayList(u8) = .empty;
    var diag = try Diagnostic.init(alloc, source);
    Parser.mergeErrorsInto(result.errors, &diag, alloc);
    try writeDiagnosticsBare(&buf, alloc, diag.diagnostics.items);

    return .{
        .wasm = try alloc.dupe(u8, result.wasm),
        .original_size = @intCast(result.original_size),
        .errors_json = finalize(buf),
    };
}

// =========================================================================
// Tests
// =========================================================================

test "minifyJsonToJson: produces well-formed envelope" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "fn main() { let x = 1; }";
    const json = try minifyJsonToJson(alloc, source, "{}");
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"code\":\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"originalSize\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"minifiedSize\":") != null);
}

test "validateToJson: returns wrapped object form with severity-typed counts" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    const r = try validateToJson(alloc, source, false);
    try std.testing.expect(r.valid);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"valid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"diagnostics\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"errorCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"warningCount\":") != null);
}

test "writeValidateEnvelope: canonical newline-free shape" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeValidateEnvelope(&buf, alloc, true, &.{}, 0, 0);
    try std.testing.expectEqualStrings(
        "{\"valid\":true,\"diagnostics\":[],\"errorCount\":0,\"warningCount\":0}",
        buf.items,
    );
}

test "reflectToJson: produces bindings/structs/entryPoints" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32; @compute @workgroup_size(1) fn main() {}";
    const json = try reflectToJson(alloc, source);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bindings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"entryPoints\":") != null);
}

test "renameToJson: returns edits envelope" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "fn f() { let xy: i32 = 1; let _ = xy; }";
    // Offset 16 lands on the `xy` declaration.
    const json = try renameToJson(alloc, source, 13, "ab");
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"edits\":["));
}

test "lintToResult: returns a per-file result object" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    const r = try lintToResult(alloc, source, .{});
    // Canonical per-file object: diagnostics first (no filePath on the WASM
    // surface), then the three severity counts.
    try std.testing.expect(std.mem.startsWith(u8, r.json, "{\"diagnostics\":["));
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"errorCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"warningCount\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"fixableCount\":") != null);
    try std.testing.expect(std.mem.endsWith(u8, r.json, "}"));
}

test "compileToResult: produces a valid WASM header" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    const r = try compileToResult(alloc, source, "{}");
    try std.testing.expect(r.wasm.len >= 8);
    try std.testing.expect(std.mem.eql(u8, r.wasm[0..4], "\x00asm"));
    try std.testing.expect(std.mem.eql(u8, r.errors_json, "[]"));
}
