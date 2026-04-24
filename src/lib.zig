//! C-ABI static library entry point for wgslender.
//!
//! Exports minify, validate, and reflect via C calling convention
//! for embedding in C/C++/Rust/etc. Each function manages its own
//! arena — callers only need to free returned pointers via wgslender_free_c.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgslender = @import("root.zig");
const Minifier = @import("Minifier.zig");
const Config = @import("Config.zig");
const Diagnostic = @import("Diagnostic.zig");

const OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
const OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
const OPT_MINIFY_SYNTAX: u32 = 1 << 2;
const OPT_TREE_SHAKING: u32 = 1 << 3;
const OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
const OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

/// Result from minification. Caller must call wgslender_free_result.
pub const WgslenderResult = extern struct {
    code_ptr: ?[*]const u8,
    code_len: u32,
    @"error": bool,
};

/// Minify WGSL source. Returns a WgslenderResult.
/// The result's code_ptr must be freed with wgslender_free_c.
export fn wgslender_minify_c(
    source_ptr: [*]const u8,
    source_len: u32,
    flags: u32,
) WgslenderResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    const options = Minifier.Options{
        .minify_whitespace = flags & OPT_MINIFY_WHITESPACE != 0,
        .minify_identifiers = flags & OPT_MINIFY_IDENTIFIERS != 0,
        .minify_syntax = flags & OPT_MINIFY_SYNTAX != 0,
        .tree_shaking = flags & OPT_TREE_SHAKING != 0,
        .mangle_external_bindings = flags & OPT_MANGLE_EXTERNAL != 0,
        .preserve_uniform_struct_types = flags & OPT_PRESERVE_UNIFORM_STRUCTS != 0,
    };

    const result = Minifier.minify(alloc, source, options) catch
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    const out = copyToPageAllocator(result.code) orelse
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    arena.deinit();

    return .{
        .code_ptr = out.ptr,
        .code_len = @intCast(out.len),
        .@"error" = false,
    };
}

/// Free memory returned by wgslender_minify_c.
export fn wgslender_free_c(ptr: [*]u8, len: u32) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

// =========================================================================
// Validate
// =========================================================================

const OPT_STRICT: u32 = 1 << 0;

/// Result from validation.
pub const WgslenderValidateResult = extern struct {
    valid: bool,
    json_ptr: ?[*]const u8,
    json_len: u32,
    error_count: u32,
};

/// Validate WGSL source. Returns validation result with JSON diagnostics.
/// The result's json_ptr must be freed with wgslender_free_c.
export fn wgslender_validate_c(
    source_ptr: [*]const u8,
    source_len: u32,
    flags: u32,
) WgslenderValidateResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .valid = false, .json_ptr = null, .json_len = 0, .error_count = 0 };

    const strict = flags & OPT_STRICT != 0;
    const result = wgslender.validateWithOptions(alloc, source, .{ .strict_mode = strict }) catch
        return .{ .valid = false, .json_ptr = null, .json_len = 0, .error_count = 0 };

    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    buildValidateJson(&json_buf, alloc, result) catch {
        return .{
            .valid = result.valid,
            .json_ptr = null,
            .json_len = 0,
            .error_count = result.diagnostics.errorCount(),
        };
    };

    const json_out = copyToPageAllocator(json_buf.items) orelse {
        return .{
            .valid = result.valid,
            .json_ptr = null,
            .json_len = 0,
            .error_count = result.diagnostics.errorCount(),
        };
    };

    const err_count = result.diagnostics.errorCount();
    arena.deinit();

    return .{
        .valid = result.valid,
        .json_ptr = json_out.ptr,
        .json_len = @intCast(json_out.len),
        .error_count = err_count,
    };
}

// =========================================================================
// Reflect
// =========================================================================

/// Result with JSON data.
pub const WgslenderJsonResult = extern struct {
    json_ptr: ?[*]const u8,
    json_len: u32,
    @"error": bool,
};

/// Reflect WGSL source. Returns JSON with bindings, structs, and entry points.
/// The result's json_ptr must be freed with wgslender_free_c.
export fn wgslender_reflect_c(
    source_ptr: [*]const u8,
    source_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    var result = wgslender.reflect(alloc, source) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    result.toJson(&json_buf, alloc) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const json_out = copyToPageAllocator(json_buf.items) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    arena.deinit();

    return .{
        .json_ptr = json_out.ptr,
        .json_len = @intCast(json_out.len),
        .@"error" = false,
    };
}

// =========================================================================
// Minify with JSON options
// =========================================================================

/// Minify WGSL source with JSON options (same format as config files).
/// The result's code_ptr must be freed with wgslender_free_c.
export fn wgslender_minify_json_c(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) WgslenderResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    const opts_slice = opts_ptr[0..opts_len];
    const config = Config.parseJson(alloc, opts_slice) catch Config{};
    const options = config.toOptions();

    const result = Minifier.minify(alloc, source, options) catch
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    const out = copyToPageAllocator(result.code) orelse
        return .{ .code_ptr = null, .code_len = 0, .@"error" = true };

    arena.deinit();

    return .{
        .code_ptr = out.ptr,
        .code_len = @intCast(out.len),
        .@"error" = false,
    };
}

// =========================================================================
// Helpers
// =========================================================================

fn buildValidateJson(
    json_buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    result: anytype,
) Allocator.Error!void {
    try json_buf.appendSlice(alloc, "{\"valid\":");
    try json_buf.appendSlice(alloc, if (result.valid) "true" else "false");
    try json_buf.appendSlice(alloc, ",\"diagnostics\":[");
    for (result.diagnostics.diagnostics.items, 0..) |*entry, i| {
        if (i > 0) try json_buf.append(alloc, ',');
        try Diagnostic.entryToJson(json_buf, alloc, entry);
    }
    try json_buf.appendSlice(alloc, "],\"errorCount\":");
    try Diagnostic.appendInt(json_buf, alloc, result.diagnostics.errorCount());
    try json_buf.appendSlice(alloc, ",\"warningCount\":");
    try Diagnostic.appendInt(json_buf, alloc, result.diagnostics.warningCount());
    try json_buf.appendSlice(alloc, "}");
}

fn makeSentinelSource(
    alloc: Allocator,
    source_ptr: [*]const u8,
    source_len: u32,
) ?[:0]const u8 {
    const buf = alloc.alloc(u8, source_len + 1) catch return null;
    @memcpy(buf[0..source_len], source_ptr[0..source_len]);
    buf[source_len] = 0;
    return buf[0..source_len :0];
}

fn copyToPageAllocator(data: []const u8) ?[]u8 {
    const out = std.heap.page_allocator.alloc(u8, data.len) catch return null;
    @memcpy(out, data);
    return out;
}

// =========================================================================
// Edits (rename / findReferences) — C FFI
// =========================================================================

const Edits = wgslender.Edits;

/// Find all references to the symbol under `offset`. Returns JSON:
///   {"references":[{"start":N,"end":N,"isWrite":bool},...]}
/// or {"references":[],"error":"..."} on parse error, or
///    {"references":[]} if no symbol is under the offset.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_find_references_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    include_declaration: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse {
        return jsonOutPayload(
            "{\"references\":[],\"error\":\"parse error\"}",
        );
    };

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return jsonOutPayload("{\"references\":[]}");

    const refs = Edits.findReferences(alloc, module, target, include_declaration != 0) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildReferencesJson(&json, alloc, refs) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    return jsonOutPayload(json.items);
}

/// Compute text edits that rename the symbol at `offset` to `new_name`.
/// Returns JSON: {"edits":[{"start":N,"end":N,"newText":"..."}, ...]}
/// or {"edits":[],"error":"..."} on failure.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_rename_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const new_name = new_name_ptr[0..new_name_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return jsonOutPayload("{\"edits\":[],\"error\":\"invalid identifier\"}");
    }

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse {
        return jsonOutPayload("{\"edits\":[],\"error\":\"parse error\"}");
    };

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return jsonOutPayload("{\"edits\":[],\"error\":\"symbol not found\"}");

    const maybe_edits = Edits.renameEdits(alloc, module, target, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const edits = maybe_edits orelse {
        return jsonOutPayload("{\"edits\":[],\"error\":\"invalid identifier\"}");
    };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildEditsJson(&json, alloc, edits, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    return jsonOutPayload(json.items);
}

/// Rename-and-apply. Returns JSON:
///   {"ok":true,"source":"...","edits":[...]}
/// on success, or
///   {"ok":false,"source":"<original>","edits":[],"error":"..."}
/// on failure. `source` is always present.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_rename_apply_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_copy = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const new_name = new_name_ptr[0..new_name_len];
    const original = source_ptr[0..source_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return buildRenameApplyFailureJson(alloc, original, "invalid identifier");
    }

    const analysis = wgslender.analyzeWithOptions(alloc, source_copy, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse return buildRenameApplyFailureJson(alloc, original, "parse error");

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return buildRenameApplyFailureJson(alloc, original, "symbol not found");

    const maybe_edits = Edits.renameEdits(alloc, module, target, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const edits = maybe_edits orelse
        return buildRenameApplyFailureJson(alloc, original, "invalid identifier");

    const rewritten = Edits.applyEdits(alloc, original, edits) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildRenameApplySuccessJson(&json, alloc, rewritten, edits, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    return jsonOutPayload(json.items);
}

fn buildReferencesJson(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    refs: []const Edits.Reference,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"references\":[");
    for (refs, 0..) |r, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"start\":");
        try Diagnostic.appendInt(buf, alloc, r.start);
        try buf.appendSlice(alloc, ",\"end\":");
        try Diagnostic.appendInt(buf, alloc, r.end);
        try buf.appendSlice(alloc, ",\"isWrite\":");
        try buf.appendSlice(alloc, if (r.is_write) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
}

fn buildEditsJson(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    edits: []const Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"edits\":[");
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(alloc, ',');
        try writeEditJsonLib(buf, alloc, e, new_text);
    }
    try buf.appendSlice(alloc, "]}");
}

fn writeEditJsonLib(
    buf: *std.ArrayListUnmanaged(u8),
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

fn buildRenameApplySuccessJson(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    rewritten: []const u8,
    edits: []const Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"ok\":true,\"source\":\"");
    try Diagnostic.appendJsonEscaped(buf, alloc, rewritten);
    try buf.appendSlice(alloc, "\",\"edits\":[");
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(alloc, ',');
        try writeEditJsonLib(buf, alloc, e, new_text);
    }
    try buf.appendSlice(alloc, "]}");
}

fn buildRenameApplyFailureJson(
    alloc: Allocator,
    original: []const u8,
    msg: []const u8,
) WgslenderJsonResult {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buildFailureJsonImpl(&buf, alloc, original, msg) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    return jsonOutPayload(buf.items);
}

fn buildFailureJsonImpl(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    original: []const u8,
    msg: []const u8,
) Allocator.Error!void {
    try buf.appendSlice(alloc, "{\"ok\":false,\"source\":\"");
    try Diagnostic.appendJsonEscaped(buf, alloc, original);
    try buf.appendSlice(alloc, "\",\"edits\":[],\"error\":\"");
    try Diagnostic.appendJsonEscaped(buf, alloc, msg);
    try buf.appendSlice(alloc, "\"}");
}

fn jsonOutPayload(json: []const u8) WgslenderJsonResult {
    const out = copyToPageAllocator(json) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    return .{
        .json_ptr = out.ptr,
        .json_len = @intCast(out.len),
        .@"error" = false,
    };
}

// =========================================================================
// Stable IDs — C FFI
// =========================================================================

const StableIdMod = wgslender.StableId;

/// Resolve `offset` to a reparse-stable ID. Returns JSON:
///   {"stableId":"v1:fn:main/block#0/let:x"}
/// or `{"stableId":null}` / `{"stableId":null,"error":"..."}`.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_stable_id_at_offset_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse {
        return jsonOutPayload("{\"stableId\":null,\"error\":\"parse error\"}");
    };

    const maybe_id = StableIdMod.stableIdAtOffset(alloc, module, offset) catch |e| switch (e) {
        error.OutOfMemory => return .{ .json_ptr = null, .json_len = 0, .@"error" = true },
        error.IdTooLong => return jsonOutPayload("{\"stableId\":null,\"error\":\"id too long\"}"),
    };
    if (maybe_id) |id| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(alloc, "{\"stableId\":\"") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        Diagnostic.appendJsonEscaped(&buf, alloc, id.bytes) catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        buf.appendSlice(alloc, "\"}") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        return jsonOutPayload(buf.items);
    }
    return jsonOutPayload("{\"stableId\":null}");
}

/// Resolve a stable ID to its declaration byte range in the current source.
/// Returns JSON `{"start":N,"end":N}` or
/// `{"start":null,"end":null,"error":"..."}`.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_locate_stable_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const id_bytes = id_ptr[0..id_len];

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse {
        return jsonOutPayload(
            "{\"start\":null,\"end\":null,\"error\":\"parse error\"}",
        );
    };

    if (StableIdMod.locateStableId(module, id_bytes)) |range| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(alloc, "{\"start\":") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        Diagnostic.appendInt(&buf, alloc, range.start) catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        buf.appendSlice(alloc, ",\"end\":") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        Diagnostic.appendInt(&buf, alloc, range.end) catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        buf.appendSlice(alloc, "}") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        return jsonOutPayload(buf.items);
    }
    return jsonOutPayload("{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

/// Rename the symbol identified by stable ID. Same shape as
/// `wgslender_rename_c`.
export fn wgslender_rename_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const id_bytes = id_ptr[0..id_len];
    const new_name = new_name_ptr[0..new_name_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return jsonOutPayload("{\"edits\":[],\"error\":\"invalid identifier\"}");
    }

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse {
        return jsonOutPayload("{\"edits\":[],\"error\":\"parse error\"}");
    };

    const target = StableIdMod.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return jsonOutPayload(
        "{\"edits\":[],\"error\":\"symbol not found\"}",
    );

    const maybe_edits = Edits.renameEdits(alloc, module, target, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const edits = maybe_edits orelse
        return jsonOutPayload("{\"edits\":[],\"error\":\"invalid identifier\"}");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildEditsJson(&json, alloc, edits, new_name) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    return jsonOutPayload(json.items);
}

// =========================================================================
// Declaration / type edits — C FFI (addressed by stable ID)
// =========================================================================

/// Locate the full declaration span for a stable ID. Returns JSON
/// `{"start":N,"end":N}` on success or `{"start":null,"end":null,"error":"..."}`.
/// Caller must free json_ptr with wgslender_free_c.
export fn wgslender_locate_declaration_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) WgslenderJsonResult {
    return locateRangeImplC(source_ptr, source_len, id_ptr, id_len, StableIdMod.locateDeclaration);
}

/// Locate the type-annotation span for a stable ID. Same JSON shape as
/// wgslender_locate_declaration_c.
export fn wgslender_locate_type_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) WgslenderJsonResult {
    return locateRangeImplC(source_ptr, source_len, id_ptr, id_len, StableIdMod.locateType);
}

fn locateRangeImplC(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    locator: *const fn (*wgslender.Ast.Module, []const u8) ?StableIdMod.Range,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const id_bytes = id_ptr[0..id_len];

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse
        return jsonOutPayload("{\"start\":null,\"end\":null,\"error\":\"parse error\"}");

    if (locator(module, id_bytes)) |range| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(alloc, "{\"start\":") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        Diagnostic.appendInt(&buf, alloc, range.start) catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        buf.appendSlice(alloc, ",\"end\":") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        Diagnostic.appendInt(&buf, alloc, range.end) catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        buf.appendSlice(alloc, "}") catch
            return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
        return jsonOutPayload(buf.items);
    }
    return jsonOutPayload("{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

/// Remove a declaration by stable ID. Same output shape as
/// wgslender_rename_by_id_c.
export fn wgslender_remove_declaration_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const id_bytes = id_ptr[0..id_len];

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse
        return jsonOutPayload("{\"edits\":[],\"error\":\"parse error\"}");

    const target = StableIdMod.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return jsonOutPayload(
        "{\"edits\":[],\"error\":\"symbol not found\"}",
    );

    const maybe_edits = Edits.removeDeclarationEdit(alloc, module, target) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const edits = maybe_edits orelse
        return jsonOutPayload("{\"edits\":[],\"error\":\"not a removable declaration\"}");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildEditsJson(&json, alloc, edits, "") catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    return jsonOutPayload(json.items);
}

/// Change a type annotation by stable ID. Same output shape as
/// wgslender_rename_by_id_c.
export fn wgslender_change_type_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_type_ptr: [*]const u8,
    new_type_len: u32,
) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = makeSentinelSource(alloc, source_ptr, source_len) orelse
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const id_bytes = id_ptr[0..id_len];
    const new_type = new_type_ptr[0..new_type_len];

    const analysis = wgslender.analyzeWithOptions(alloc, source, .{}) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };

    const module = analysis.module orelse
        return jsonOutPayload("{\"edits\":[],\"error\":\"parse error\"}");

    const target = StableIdMod.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return jsonOutPayload(
        "{\"edits\":[],\"error\":\"symbol not found\"}",
    );

    const maybe_edits = Edits.changeTypeEdit(alloc, module, target, new_type) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    const edits = maybe_edits orelse
        return jsonOutPayload(
            "{\"edits\":[],\"error\":\"no type annotation or invalid replacement\"}",
        );

    var json: std.ArrayListUnmanaged(u8) = .empty;
    buildEditsJson(&json, alloc, edits, new_type) catch
        return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
    return jsonOutPayload(json.items);
}

// =========================================================================
// Version / Free
// =========================================================================

/// Return the version string and length.
export fn wgslender_version_c(len: *u32) [*]const u8 {
    len.* = wgslender.version.len;
    return wgslender.version.ptr;
}
