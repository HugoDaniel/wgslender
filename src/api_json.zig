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
const Builtins = @import("Builtins.zig");
const Predeclared = @import("Predeclared.zig");
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
// Call shape
// =========================================================================

/// How a call expression's callee is classified. `user` — the callee
/// resolves to a function declared in this module (`spOver(...)`), or is a
/// name that resolves to nothing (only a user-declared function can be
/// called by identifier in WGSL, so an unresolved callee is reported as
/// `user` rather than guessed at). `builtin` — a builtin function
/// (`textureSample`, `sin`, `bitcast<T>`). `constructor` — a type
/// constructor: predeclared (`vec2f`, `f32`, `vec3<f32>`, `array<T, N>`)
/// or user-declared struct / alias (`S(...)`).
pub const CallShapeKind = enum {
    user,
    builtin,
    constructor,

    pub fn jsonString(self: CallShapeKind) []const u8 {
        return switch (self) {
            .user => "user",
            .builtin => "builtin",
            .constructor => "constructor",
        };
    }
};

/// One call expression, with UTF-8 byte spans into the analyzed source.
/// All spans are half-open `[start, end)` offsets — the convention
/// `Edits.zig` pins (byte offsets, not UTF-16, not line/column).
pub const CallShapeCall = struct {
    kind: CallShapeKind,
    /// Callee as written: the identifier for `f(...)`, the leading type
    /// name for `vec3<f32>(...)`. Empty on a recovery-synthesized call
    /// that carries no callee at all.
    callee: []const u8,
    /// Span of the callee: the identifier for `f(...)`, the whole
    /// `vec3<f32>` type expression for a templated constructor.
    callee_span: Ast.Span,
    /// Span of the whole call expression.
    span: Ast.Span,
    /// Each argument *expression's* span, in source order.
    args: []Ast.Span,
};

/// One user function and every call expression its body contains.
pub const CallShapeFunction = struct {
    name: []const u8,
    /// Byte offset of the function's name in the source.
    name_offset: u32,
    /// `StableId` of the function declaration. Empty when the ID would
    /// exceed the length limit — dropped, not fatal, the same policy
    /// `reflect` applies to `FunctionInfo.stable_id`.
    stable_id: []const u8,
    /// Calls in source order, nested calls included: an outer call
    /// precedes every call nested inside its callee and arguments, and an
    /// argument's span contains the whole span of a call nested in it.
    calls: []CallShapeCall,
};

/// Result of `collectCallShapes`.
pub const CallShapes = struct {
    functions: []CallShapeFunction,
    /// Syntax errors the recovery parser reported while producing the
    /// module. Non-zero means some regions of the source were skipped;
    /// every function the parser recovered is still reported, with every
    /// call found in it. Nothing is silently dropped.
    parse_errors: u32,
};

/// Parse `source` and collect every call expression per user function.
///
/// Runs the Lexer + Parser only — not the validator — mirroring `reflect`:
/// the query answers what the text says, and the parser's own recovery
/// error count stays cleanly separable from validation diagnostics.
/// Returns null only when parsing failed outright (no module at all);
/// allocation failure propagates as `error.OutOfMemory`.
///
/// `filter`, when non-null, narrows the result to the single function
/// with that name; the walk itself is unaffected.
pub fn collectCallShapes(
    alloc: Allocator,
    source: [:0]const u8,
    filter: ?[]const u8,
) Allocator.Error!?CallShapes {
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    var functions: std.ArrayList(CallShapeFunction) = .empty;
    for (module.declarations.items) |decl| switch (decl) {
        .function => |fn_decl| {
            if (!fn_decl.name.isValid()) continue;
            const idx = fn_decl.name.index();
            if (idx >= module.symbols.items.len) continue;
            const sym = module.symbols.items[idx];
            if (filter) |f| {
                if (!std.mem.eql(u8, f, sym.original_name)) continue;
            }
            try functions.append(alloc, try callShapeForFunction(alloc, module, fn_decl, sym));
        },
        else => {},
    };

    return .{
        .functions = functions.items,
        .parse_errors = @intCast(parser.errors.items.len),
    };
}

fn callShapeForFunction(
    alloc: Allocator,
    module: *const Ast.Module,
    fn_decl: *Ast.FunctionDecl,
    sym: Ast.Symbol,
) Allocator.Error!CallShapeFunction {
    // Same error handling as `reflect/CallGraph.zig`: an over-long id is
    // dropped, leaving `stable_id` empty, rather than failing the query.
    var stable_id: []const u8 = "";
    if (StableId.stableIdFor(alloc, module, fn_decl.name)) |maybe_id| {
        if (maybe_id) |id| stable_id = id.bytes;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IdTooLong => {},
    }

    var walk = CallShapeWalk{
        .alloc = alloc,
        .module = module,
        .source = module.source,
        .calls = .empty,
    };
    if (fn_decl.body) |body| try walk.walkBody(body);

    // Pre-order on the parser's tree is already source order (a call's
    // span starts before any span nested inside it); the stable sort is
    // cheap insurance for recovery-shaped trees where spans may tie.
    std.sort.insertion(CallShapeCall, walk.calls.items, {}, callSpanBefore);

    return .{
        .name = sym.original_name,
        .name_offset = sym.loc,
        .stable_id = stable_id,
        .calls = walk.calls.items,
    };
}

fn callSpanBefore(_: void, a: CallShapeCall, b: CallShapeCall) bool {
    if (a.span.start != b.span.start) return a.span.start < b.span.start;
    return a.span.end < b.span.end;
}

/// Body walker for one function: a read-only traversal in the shape of
/// `reflect/CallGraph.zig`'s walk, recording every call expression it
/// reaches, then descending into the callee expression and each argument
/// so nested calls are collected too.
const CallShapeWalk = struct {
    alloc: Allocator,
    module: *const Ast.Module,
    source: []const u8,
    calls: std.ArrayList(CallShapeCall),

    fn walkBody(w: *CallShapeWalk, body: *Ast.CompoundStmt) Allocator.Error!void {
        for (body.stmts.items) |stmt| try w.walkStmt(stmt);
    }

    fn walkStmt(w: *CallShapeWalk, stmt: Ast.Stmt) Allocator.Error!void {
        switch (stmt) {
            .compound => |s| try w.walkBody(s),
            .@"return" => |s| if (s.value) |v| try w.walkExpr(v),
            .@"if" => |s| {
                try w.walkExpr(s.condition);
                try w.walkBody(s.body);
                if (s.else_branch) |e| try w.walkStmt(e);
            },
            .@"switch" => |s| {
                try w.walkExpr(s.expr);
                for (s.cases.items) |c| {
                    for (c.selectors.items) |sel| try w.walkExpr(sel);
                    try w.walkBody(c.body);
                }
            },
            .@"for" => |s| {
                if (s.init_stmt) |i| try w.walkStmt(i);
                if (s.condition) |c| try w.walkExpr(c);
                if (s.update) |u| try w.walkStmt(u);
                try w.walkBody(s.body);
            },
            .@"while" => |s| {
                try w.walkExpr(s.condition);
                try w.walkBody(s.body);
            },
            .loop => |s| {
                try w.walkBody(s.body);
                if (s.continuing) |c| try w.walkBody(c);
            },
            .break_if => |s| try w.walkExpr(s.condition),
            .assign => |s| {
                try w.walkExpr(s.left);
                try w.walkExpr(s.right);
            },
            // `_ = f(x);` evaluates its RHS like any other expression, so
            // calls in it are part of the function's shape.
            .phony => |s| try w.walkExpr(s.expr),
            .incr_decr => |s| try w.walkExpr(s.expr),
            .call => |s| try w.walkExpr(.{ .call = s.call }),
            .decl => |s| switch (s.decl) {
                .@"const" => |d| if (d.initializer) |e| try w.walkExpr(e),
                .let => |d| if (d.initializer) |e| try w.walkExpr(e),
                .@"var" => |d| if (d.initializer) |e| try w.walkExpr(e),
                else => {},
            },
            .@"break", .@"continue", .discard => {},
        }
    }

    fn walkExpr(w: *CallShapeWalk, expr: Ast.Expr) Allocator.Error!void {
        switch (expr) {
            .literal, .ident => {},
            .paren => |p| try w.walkExpr(p.expr),
            .unary => |u| try w.walkExpr(u.operand),
            .binary => |b| {
                try w.walkExpr(b.left);
                try w.walkExpr(b.right);
            },
            .member => |m| try w.walkExpr(m.base),
            .index => |ix| {
                try w.walkExpr(ix.base);
                try w.walkExpr(ix.idx);
            },
            .call => |c| {
                try w.recordCall(c);
                // Record the outer call first, then walk the callee
                // expression and the arguments left-to-right: pre-order
                // keeps the flat list in source order.
                if (c.func) |f| try w.walkExpr(f);
                for (c.args.items) |arg| try w.walkExpr(arg);
            },
        }
    }

    fn recordCall(w: *CallShapeWalk, call: *Ast.CallExpr) Allocator.Error!void {
        const spans = try w.alloc.alloc(Ast.Span, call.args.items.len);
        for (call.args.items, 0..) |arg, i| spans[i] = arg.span();

        const callee = classifyCallee(w.module, w.source, call);

        try w.calls.append(w.alloc, .{
            .kind = callee.kind,
            .callee = callee.name,
            .callee_span = callee.span,
            .span = call.span,
            .args = spans,
        });
    }
};

const ClassifiedCallee = struct {
    kind: CallShapeKind,
    name: []const u8,
    span: Ast.Span,
};

/// Resolve a call's callee to a name, a span, and a classification.
/// Regular and `bitcast<T>` calls carry the callee as `func`; templated
/// constructors (`vec3<f32>(...)`) carry it as `template_type` with
/// `func == null`. A `(f)(x)` spelling is unwrapped; any other non-ident
/// callee expression is reported by its source text.
fn classifyCallee(module: *const Ast.Module, source: []const u8, call: *const Ast.CallExpr) ClassifiedCallee {
    if (call.func) |func| {
        var f = func;
        while (f == .paren) f = f.paren.expr;
        switch (f) {
            .ident => |id| return .{
                .kind = calleeKindForName(module, id.ref, id.name),
                .name = id.name,
                .span = id.span,
            },
            else => {
                const span = f.span();
                const text = span.slice(source);
                return .{
                    .kind = calleeKindForName(module, .none, text),
                    .name = text,
                    .span = span,
                };
            },
        }
    }
    if (call.template_type) |tt| {
        const span = tt.span();
        const text = span.slice(source);
        // `vec3<f32>` — the name is the leading identifier; the callee
        // span is the whole type expression as written.
        const name = if (std.mem.indexOfScalar(u8, text, '<')) |lt| text[0..lt] else text;
        return .{
            .kind = calleeKindForName(module, .none, name),
            .name = name,
            .span = span,
        };
    }
    return .{ .kind = .user, .name = "", .span = .empty };
}

/// Decide the `kind` for a callee. A resolved symbol wins — a user `fn
/// sin` shadows the builtin table, and a struct / alias target is a
/// constructor — otherwise the name is matched against the predeclared
/// type-name inventory (constructors) and then the builtin function
/// table. An unresolved name is `user`: WGSL has no other way to spell a
/// call by identifier.
fn calleeKindForName(module: *const Ast.Module, ref: Ast.SymbolIndex, name: []const u8) CallShapeKind {
    if (ref.isValid()) {
        const idx = ref.index();
        if (idx < module.symbols.items.len) {
            switch (module.symbols.items[idx].kind) {
                .function => return .user,
                .@"struct", .alias => return .constructor,
                else => {},
            }
        }
    }
    if (isPredeclaredConstructorName(name)) return .constructor;
    if (Builtins.lookup(name) != null) return .builtin;
    return .user;
}

/// True for predeclared *type-constructor* spellings: scalar type names
/// (`f32`, `bool`, …), vec/mat shorthands (`vec2f`, `mat2x2`, …) and the
/// non-shorthand template type names (`array`, `ptr`, `atomic`). The last
/// group is not callable as a value constructor in valid WGSL, but a call
/// spelled with one is still constructor-shaped, so it classifies through
/// the same `Predeclared` inventory rather than a second table.
fn isPredeclaredConstructorName(name: []const u8) bool {
    for (Predeclared.scalar_type_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    if (Predeclared.parseVecShorthand(name) != null) return true;
    if (Predeclared.parseMatShorthand(name) != null) return true;
    for (Predeclared.other_type_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// The call-shape query: every call expression per user function, as JSON.
///
/// Shape (spans are `[start, end)` UTF-8 byte offsets into `source`):
///
/// ```json
/// {"functions":[
///   {"name":"main","name_offset":42,"stable_id":"v1:fn:main","calls":[
///     {"kind":"user","callee":"spOver",
///      "callee_span":[50,56],"span":[50,80],
///      "args":[[57,60],[62,79]]}]}],
///  "error":"parse errors: 2"}
/// ```
///
/// Parse-error discipline: the parser is recovery-oriented, so the query
/// answers for the functions that parsed — `functions` carries each with
/// every call found in it — and appends `"error":"parse errors: N"`
/// noting how many syntax errors were recovered, so a consumer can treat
/// spans inside the broken regions with suspicion without discarding the
/// clean ones. A total parse failure (no module at all) returns
/// `{"functions":[],"error":"parse error"}`, matching the other query
/// envelopes in this layer. `error` is never thrown — the package's
/// no-throw convention.
pub fn callShapeToJson(
    alloc: Allocator,
    source: [:0]const u8,
    filter: ?[]const u8,
) Allocator.Error![]u8 {
    const shapes = (try collectCallShapes(alloc, source, filter)) orelse
        return dupeLiteral(alloc, "{\"functions\":[],\"error\":\"parse error\"}");

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"functions\":[");
    for (shapes.functions, 0..) |f, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"name\":\"");
        try Diagnostic.appendJsonEscaped(&buf, alloc, f.name);
        try buf.appendSlice(alloc, "\",\"name_offset\":");
        try Diagnostic.appendInt(&buf, alloc, f.name_offset);
        try buf.appendSlice(alloc, ",\"stable_id\":\"");
        try Diagnostic.appendJsonEscaped(&buf, alloc, f.stable_id);
        try buf.appendSlice(alloc, "\",\"calls\":[");
        for (f.calls, 0..) |c, j| {
            if (j > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"kind\":\"");
            try buf.appendSlice(alloc, c.kind.jsonString());
            try buf.appendSlice(alloc, "\",\"callee\":\"");
            try Diagnostic.appendJsonEscaped(&buf, alloc, c.callee);
            try buf.appendSlice(alloc, "\",\"callee_span\":");
            try writeSpanArray(&buf, alloc, c.callee_span);
            try buf.appendSlice(alloc, ",\"span\":");
            try writeSpanArray(&buf, alloc, c.span);
            try buf.appendSlice(alloc, ",\"args\":[");
            for (c.args, 0..) |a, k| {
                if (k > 0) try buf.append(alloc, ',');
                try writeSpanArray(&buf, alloc, a);
            }
            try buf.appendSlice(alloc, "]}");
        }
        try buf.appendSlice(alloc, "]}");
    }
    try buf.append(alloc, ']');
    if (shapes.parse_errors > 0) {
        try buf.appendSlice(alloc, ",\"error\":\"parse errors: ");
        try Diagnostic.appendInt(&buf, alloc, shapes.parse_errors);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, '}');
    return finalize(buf);
}

/// Append a span as a JSON `[start, end]` pair.
fn writeSpanArray(buf: *std.ArrayList(u8), alloc: Allocator, span: Ast.Span) Allocator.Error!void {
    try buf.append(alloc, '[');
    try Diagnostic.appendInt(buf, alloc, span.start);
    try buf.append(alloc, ',');
    try Diagnostic.appendInt(buf, alloc, span.end);
    try buf.append(alloc, ']');
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

// -------------------------------------------------------------------------
// Call shape — collection (traversal + classification)
// -------------------------------------------------------------------------

fn expectCallAt(
    call: CallShapeCall,
    source: []const u8,
    expected_kind: CallShapeKind,
    expected_callee: []const u8,
) !void {
    try std.testing.expectEqual(expected_kind, call.kind);
    try std.testing.expectEqualStrings(expected_callee, call.callee);
    // The callee span starts with the callee name inside the source and
    // sits inside the whole call span. (For a templated constructor the
    // span continues past the name — `vec3<f32>` — which the specific
    // tests assert explicitly.)
    try std.testing.expect(std.mem.startsWith(u8, call.callee_span.slice(source), expected_callee));
    try std.testing.expect(call.span.start <= call.callee_span.start);
    try std.testing.expect(call.callee_span.end <= call.span.end);
}

test "collectCallShapes: nested calls in source order, arg span contains inner call" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "fn spOver(a: f32, b: f32) -> f32 { return a + b; }" ++
        "fn layer_sun(p: f32) -> f32 { return p; }" ++
        "fn main() { let x = spOver(1.0, layer_sun(2.0)); }";
    const shapes = (try collectCallShapes(alloc, source, null)).?;
    try std.testing.expectEqual(@as(u32, 0), shapes.parse_errors);
    try std.testing.expectEqual(@as(usize, 3), shapes.functions.len);

    // spOver and layer_sun have no calls of their own; main has exactly
    // the two from the one statement, outer first.
    const by_name = struct {
        fn find(ss: []const CallShapeFunction, name: []const u8) ?CallShapeFunction {
            for (ss) |f| if (std.mem.eql(u8, f.name, name)) return f;
            return null;
        }
    };
    const main = by_name.find(shapes.functions, "main") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), main.calls.len);

    try expectCallAt(main.calls[0], source, .user, "spOver");
    try expectCallAt(main.calls[1], source, .user, "layer_sun");

    // Outer call's whole span starts at `spOver` and the second argument
    // span contains the inner call's whole span.
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "spOver(1.0").?)), main.calls[0].span.start);
    try std.testing.expectEqual(@as(usize, 2), main.calls[0].args.len);
    const inner = main.calls[1];
    try std.testing.expect(main.calls[0].args[1].start <= inner.span.start);
    try std.testing.expect(inner.span.end <= main.calls[0].args[1].end);
    // Argument spans spell their expressions.
    try std.testing.expectEqualStrings("1.0", main.calls[0].args[0].slice(source));
    try std.testing.expectEqualStrings("layer_sun(2.0)", main.calls[0].args[1].slice(source));
}

test "collectCallShapes: zero-arg, constructor, and builtin calls" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "struct C { r: f32, g: f32, b: f32 }" ++
        "fn main() {" ++
        "  let a = vec2f();" ++
        "  let b = vec3<f32>(1.0, 2.0, 3.0);" ++
        "  let c = C(0.5, 0.5, 0.5);" ++
        "  let d = f32(1);" ++
        "  let e = min(a.x, b.x);" ++
        "}";
    const shapes = (try collectCallShapes(alloc, source, null)).?;
    try std.testing.expectEqual(@as(usize, 1), shapes.functions.len);
    const calls = shapes.functions[0].calls;

    // Source order: vec2f, vec3<f32>, C, f32, min.
    try std.testing.expectEqual(@as(usize, 5), calls.len);
    try expectCallAt(calls[0], source, .constructor, "vec2f");
    try std.testing.expectEqual(@as(usize, 0), calls[0].args.len);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "vec2f()").?)), calls[0].span.start);

    // Templated constructor: name is the leading identifier, callee span
    // is the whole `vec3<f32>` type expression, all three args reported.
    try expectCallAt(calls[1], source, .constructor, "vec3");
    try std.testing.expectEqualStrings("vec3<f32>", calls[1].callee_span.slice(source));
    try std.testing.expectEqual(@as(usize, 3), calls[1].args.len);
    try std.testing.expectEqualStrings("2.0", calls[1].args[1].slice(source));

    // User struct constructor and scalar conversion.
    try expectCallAt(calls[2], source, .constructor, "C");
    try expectCallAt(calls[3], source, .constructor, "f32");

    // Builtin function call.
    try expectCallAt(calls[4], source, .builtin, "min");
    try std.testing.expectEqual(@as(usize, 2), calls[4].args.len);
}

test "collectCallShapes: filter narrows to one function by name" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "fn one() -> f32 { return sin(1.0); }" ++
        "fn two() -> f32 { return cos(2.0); }";
    const all = (try collectCallShapes(alloc, source, null)).?;
    try std.testing.expectEqual(@as(usize, 2), all.functions.len);

    const filtered = (try collectCallShapes(alloc, source, "two")).?;
    try std.testing.expectEqual(@as(usize, 1), filtered.functions.len);
    try std.testing.expectEqualStrings("two", filtered.functions[0].name);
    try std.testing.expectEqual(@as(usize, 1), filtered.functions[0].calls.len);
    try expectCallAt(filtered.functions[0].calls[0], source, .builtin, "cos");

    // A filter that matches nothing reports no functions, no error.
    const none = (try collectCallShapes(alloc, source, "nope")).?;
    try std.testing.expectEqual(@as(usize, 0), none.functions.len);
}

test "collectCallShapes: calls across statements and control flow" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\fn f(x: f32) -> f32 { return x; }
        \\fn main() {
        \\  var t = f(0.0);
        \\  if (t > 0.5) { t = f(t); } else { t = f32(1); }
        \\  for (var i = 0; i < 2; i++) { t += f(t); }
        \\  switch (i32(t)) { case 1: { t = f(t); } default: {} }
        \\  _ = f(t);
        \\  while (t < 1.0) { t = f(t + 0.1); }
        \\  return;
        \\}
    ;
    const shapes = (try collectCallShapes(alloc, source, "main")).?;
    try std.testing.expectEqual(@as(u32, 0), shapes.parse_errors);
    const calls = shapes.functions[0].calls;
    // var init, if-then, if-else (f32), for body, switch scrutinee (i32),
    // switch case body, phony, while body — 8 calls in source order.
    try std.testing.expectEqual(@as(usize, 8), calls.len);
    for (calls, 0..) |call, i| {
        const expected: []const u8 = switch (i) {
            2 => "f32",
            4 => "i32",
            else => "f",
        };
        try std.testing.expectEqualStrings(expected, call.callee);
    }
    // Strictly increasing source order.
    var prev_start: u32 = 0;
    for (calls) |call| {
        try std.testing.expect(call.span.start >= prev_start);
        prev_start = call.span.start;
    }
}

test "collectCallShapes: function identity carries name, offset, stable id" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 = "fn helper() -> f32 { return 1.0; }";
    const shapes = (try collectCallShapes(alloc, source, null)).?;
    const f = shapes.functions[0];
    try std.testing.expectEqualStrings("helper", f.name);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "helper").?)), f.name_offset);
    try std.testing.expectEqualStrings("v1:fn:helper", f.stable_id);
    try std.testing.expectEqual(@as(usize, 0), f.calls.len);
}

test "collectCallShapes: recovery parse keeps functions, counts parse errors" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One syntactically broken function followed by a good one: the
    // recovery parser retains what it can and the error count is > 0.
    const source: [:0]const u8 =
        "fn broken( { let x = ; }" ++
        "fn good() -> f32 { return sin(1.0); }";
    const shapes = (try collectCallShapes(alloc, source, null)).?;
    try std.testing.expect(shapes.parse_errors > 0);
    var saw_good = false;
    for (shapes.functions) |f| {
        if (std.mem.eql(u8, f.name, "good")) {
            saw_good = true;
            try std.testing.expectEqual(@as(usize, 1), f.calls.len);
            try expectCallAt(f.calls[0], source, .builtin, "sin");
        }
    }
    try std.testing.expect(saw_good);
}

// -------------------------------------------------------------------------
// Call shape — JSON golden tests
// -------------------------------------------------------------------------

test "callShapeToJson: golden JSON, nested calls and kinds" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "fn inner(p: f32) -> f32 { return p; }" ++
        "fn main() { let x = vec2f(1.0, inner(2.0)); }";
    const json = try callShapeToJson(alloc, source, null);

    const inner_off = std.mem.indexOf(u8, source, "inner").?; // declaration name
    const main_off = std.mem.indexOf(u8, source, "main").?;
    const outer = std.mem.indexOf(u8, source, "vec2f(1.0").?; // whole outer call
    const nested = std.mem.indexOf(u8, source, "inner(2.0").?;
    const expected = try std.fmt.allocPrint(
        alloc,
        "{{\"functions\":[" ++
            "{{\"name\":\"inner\",\"name_offset\":{d},\"stable_id\":\"v1:fn:inner\",\"calls\":[]}}," ++
            "{{\"name\":\"main\",\"name_offset\":{d},\"stable_id\":\"v1:fn:main\",\"calls\":[" ++
            "{{\"kind\":\"constructor\",\"callee\":\"vec2f\",\"callee_span\":[{d},{d}]," ++
            "\"span\":[{d},{d}],\"args\":[[{d},{d}],[{d},{d}]]}}," ++
            "{{\"kind\":\"user\",\"callee\":\"inner\",\"callee_span\":[{d},{d}]," ++
            "\"span\":[{d},{d}],\"args\":[[{d},{d}]]}}]}}]}}",
        .{
            inner_off, // fn inner name
            main_off, //  fn main name
            outer,          outer + 5, //  callee `vec2f`
            outer,          outer + 22, // whole `vec2f(1.0, inner(2.0))`
            outer + 6,      outer + 9, //  arg 1 `1.0`
            nested,         nested + 10, // arg 2 `inner(2.0)`
            nested,         nested + 5, //  callee `inner`
            nested,         nested + 10, // whole `inner(2.0)`
            nested + 6,     nested + 9, //  arg `2.0`
        },
    );
    try std.testing.expectEqualStrings(expected, json);
}

test "callShapeToJson: golden JSON proves UTF-8 byte offsets on non-ASCII source" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `é` is 2 bytes in UTF-8 and 1 UTF-16 code unit; every span after it
    // differs by 1 between the two conventions. Hand-computed golden:
    //   "// ré\n" is 7 bytes, `main` at 10, `sin` at [27,30), call
    //   [27,35), argument [31,34).
    const source: [:0]const u8 = "// ré\nfn main() { let x = sin(1.0); }";
    try std.testing.expectEqual(@as(usize, 7), std.mem.indexOf(u8, source, "fn main").?);
    const json = try callShapeToJson(alloc, source, null);
    try std.testing.expectEqualStrings(
        "{\"functions\":[{\"name\":\"main\",\"name_offset\":10," ++
            "\"stable_id\":\"v1:fn:main\",\"calls\":" ++
            "[{\"kind\":\"builtin\",\"callee\":\"sin\"," ++
            "\"callee_span\":[27,30],\"span\":[27,35],\"args\":[[31,34]]}]}]}",
        json,
    );
}

test "callShapeToJson: unicode identifier callee keeps byte-exact spans" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `Över` is 5 bytes in UTF-8; the callee span must cover exactly
    // those bytes (and JSON-escape nothing — it passes through as UTF-8).
    const source: [:0]const u8 = "fn Över(x: f32) -> f32 { return x; } fn main() { let y = Över(1.0); }";
    const call = std.mem.indexOf(u8, source, "Över(1.0").?;
    const json = try callShapeToJson(alloc, source, "main");
    const expected = try std.fmt.allocPrint(
        alloc,
        "{{\"functions\":[{{\"name\":\"main\",\"name_offset\":{d}," ++
            "\"stable_id\":\"v1:fn:main\",\"calls\":[{{\"kind\":\"user\"," ++
            "\"callee\":\"Över\",\"callee_span\":[{d},{d}],\"span\":[{d},{d}]," ++
            "\"args\":[[{d},{d}]]}}]}}]}}",
        .{
            std.mem.indexOf(u8, source, "main").?,
            call,        call + 5,
            call,        call + 10,
            call + 6,    call + 9,
        },
    );
    try std.testing.expectEqualStrings(expected, json);
}

test "callShapeToJson: parse errors noted, recovered functions still reported" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        "fn broken( { let x = ; }" ++
        "fn good() -> f32 { return sin(1.0); }";
    const json = try callShapeToJson(alloc, source, null);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"functions\":[{\"name\":\"broken\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"good\"") != null);
    // The recovery note rides in `error` — functions are still present.
    const note = std.mem.indexOf(u8, json, ",\"error\":\"parse errors: ").?;
    try std.testing.expect(json[json.len - 2] == '"' and json[json.len - 1] == '}');
    const count = json[note + ",\"error\":\"parse errors: ".len .. json.len - 2];
    try std.testing.expect(count.len > 0);
    for (count) |ch| try std.testing.expect(ch >= '0' and ch <= '9');
}

test "callShapeToJson: clean source emits no error field" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try callShapeToJson(alloc, "fn main() {}", null);
    try std.testing.expectEqualStrings(
        "{\"functions\":[{\"name\":\"main\",\"name_offset\":3," ++
            "\"stable_id\":\"v1:fn:main\",\"calls\":[]}]}",
        json,
    );
}
