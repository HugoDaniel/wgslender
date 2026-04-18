//! WASM entry point for wgslender.
//!
//! Exports C-ABI functions for JavaScript interop.
//! Uses pointer+length pattern for string passing (no GC, no wasm_exec.js).
//!
//! JS usage:
//!   const source_ptr = wasm.alloc(source.length);
//!   new Uint8Array(wasm.memory.buffer, source_ptr, source.length).set(encoder.encode(source));
//!   const result_ptr = wasm.wgslender_minify_json(source_ptr, source.length, opts_ptr, opts.length);
//!   // result_ptr points to: [u32 json_len][u8... json]
//!   const json_len = new DataView(wasm.memory.buffer).getUint32(result_ptr, true);
//!   const json = decoder.decode(new Uint8Array(wasm.memory.buffer, result_ptr + 4, json_len));
//!   wasm.dealloc(result_ptr, json_len + 4);

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
const SourceMap = @import("SourceMap.zig");

const wasm_allocator = std.heap.wasm_allocator;

/// Option flags (bitmask) — kept for backward compatibility
const OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
const OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
const OPT_MINIFY_SYNTAX: u32 = 1 << 2;
const OPT_TREE_SHAKING: u32 = 1 << 3;
const OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
const OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

/// Allocate memory for JS to write into.
export fn wgslender_alloc(len: u32) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free memory previously allocated.
export fn wgslender_dealloc(ptr: [*]u8, len: u32) void {
    wasm_allocator.free(ptr[0..len]);
}

/// Minify WGSL source code (flags-based, backward compatible).
/// Input: pointer to source text + length + option flags.
/// Output: pointer to result buffer [u32 len][u8... minified_code].
///         Returns null on allocation failure.
export fn wgslender_minify(source_ptr: [*]const u8, source_len: u32, flags: u32) ?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    const options = Minifier.Options{
        .minify_whitespace = flags & OPT_MINIFY_WHITESPACE != 0,
        .minify_identifiers = flags & OPT_MINIFY_IDENTIFIERS != 0,
        .minify_syntax = flags & OPT_MINIFY_SYNTAX != 0,
        .tree_shaking = flags & OPT_TREE_SHAKING != 0,
        .mangle_external_bindings = flags & OPT_MANGLE_EXTERNAL != 0,
        .preserve_uniform_struct_types = flags & OPT_PRESERVE_UNIFORM_STRUCTS != 0,
    };

    const result = Minifier.minify(wasm_allocator, source, options) catch return null;

    // Pack result as [u32 len][u8... code]
    const code = result.code;
    const out_buf = wasm_allocator.alloc(u8, 4 + code.len) catch return null;
    std.mem.writeInt(u32, out_buf[0..4], @intCast(code.len), .little);
    @memcpy(out_buf[4..][0..code.len], code);

    return out_buf.ptr;
}

/// Minify WGSL source code with JSON options and JSON result.
/// Input: source pointer+length, JSON options pointer+length.
/// Output: pointer to [u32 json_len][u8... json] where JSON is
///         {"code":"...","errors":[...],"originalSize":N,"minifiedSize":N,"sourceMap":...}
///         Returns null on allocation failure.
export fn wgslender_minify_json(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) ?[*]u8 {
    return minifyJsonImpl(source_ptr, source_len, opts_ptr, opts_len) catch return null;
}

fn minifyJsonImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    // Parse JSON options via Config
    const opts_slice = opts_ptr[0..opts_len];
    const config = Config.parseJson(wasm_allocator, opts_slice) catch Config{};
    var options = config.toOptions();

    // Handle sourceMap options from config
    if (config.source_map) |sm| {
        options.generate_source_map = sm;
    }
    if (config.source_map_sources) |sms| {
        options.source_map_options.include_source = sms;
    }

    const result = Minifier.minify(wasm_allocator, source, options) catch {
        // Return error JSON
        return packJsonResult("{\"code\":\"\",\"errors\":[{\"message\":\"minification failed\"}],\"originalSize\":0,\"minifiedSize\":0}");
    };

    // Build JSON result
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    try json_buf.appendSlice(wasm_allocator, "{\"code\":\"");
    try Diagnostic.appendJsonEscaped(&json_buf, wasm_allocator, result.code);
    try json_buf.appendSlice(wasm_allocator, "\",\"errors\":[");

    // Serialize errors
    for (result.errors, 0..) |err, i| {
        if (i > 0) try json_buf.append(wasm_allocator, ',');
        try json_buf.appendSlice(wasm_allocator, "{\"message\":\"");
        try Diagnostic.appendJsonEscaped(&json_buf, wasm_allocator, err.message);
        try json_buf.appendSlice(wasm_allocator, "\"}");
    }

    try json_buf.appendSlice(wasm_allocator, "],\"originalSize\":");
    try Diagnostic.appendInt(&json_buf, wasm_allocator, result.original_size);
    try json_buf.appendSlice(wasm_allocator, ",\"minifiedSize\":");
    try Diagnostic.appendInt(&json_buf, wasm_allocator, result.minified_size);

    // Source map
    if (result.source_map) |sm| {
        try json_buf.appendSlice(wasm_allocator, ",\"sourceMap\":");
        try sm.toJson(&json_buf, wasm_allocator);
    }

    try json_buf.append(wasm_allocator, '}');

    return packJsonResult(json_buf.items);
}

/// Validate WGSL source code.
/// Input: pointer to source text + length.
/// Output: pointer to result buffer [u32 valid (1/0)][u32 error_count][u32 json_len][u8... json_diagnostics].
///         Returns null on allocation failure.
export fn wgslender_validate(source_ptr: [*]const u8, source_len: u32) ?[*]u8 {
    return validateImpl(source_ptr, source_len) catch return null;
}

fn validateImpl(source_ptr: [*]const u8, source_len: u32) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    // Tokenize + parse
    const tokens = Lexer.tokenize(wasm_allocator, source) catch return null;
    var parser = Parser.init(wasm_allocator, source, tokens) catch return null;
    const module = parser.parse() catch {
        // Build diagnostics JSON from parse errors
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        const diag = try Diagnostic.init(wasm_allocator, source);
        try serializeParseErrors(&json_buf, parser.errors.items, &diag);
        return packValidateResultWithJson(false, parser.errors.items.len, json_buf.items);
    };

    // Check for parse errors (parser may recover without throwing)
    if (parser.errors.items.len > 0) {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        const diag = try Diagnostic.init(wasm_allocator, source);
        try serializeParseErrors(&json_buf, parser.errors.items, &diag);
        return packValidateResultWithJson(false, parser.errors.items.len, json_buf.items);
    }

    // Validate
    const result = Validator.validate(wasm_allocator, module, .{}) catch return null;
    const error_count = result.diagnostics.diagnostics.items.len;

    // Serialize diagnostics to JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    try json_buf.append(wasm_allocator, '[');
    for (result.diagnostics.diagnostics.items, 0..) |entry, i| {
        if (i > 0) try json_buf.append(wasm_allocator, ',');
        try serializeDiagnosticEntry(&json_buf, &entry);
    }
    try json_buf.append(wasm_allocator, ']');

    return packValidateResultWithJson(result.valid, error_count, json_buf.items);
}

/// Serialize parse errors as a JSON array with position info.
fn serializeParseErrors(json_buf: *std.ArrayListUnmanaged(u8), errors: []const Parser.ParseError, diag: *const Diagnostic) Allocator.Error!void {
    try json_buf.append(wasm_allocator, '[');
    for (errors, 0..) |err, i| {
        if (i > 0) try json_buf.append(wasm_allocator, ',');
        const pos = diag.makePosition(err.pos);
        try json_buf.appendSlice(wasm_allocator, "{\"severity\":\"error\",\"message\":\"");
        try Diagnostic.appendJsonEscaped(json_buf, wasm_allocator, err.message);
        try json_buf.appendSlice(wasm_allocator, "\",\"line\":");
        try Diagnostic.appendInt(json_buf, wasm_allocator, pos.line);
        try json_buf.appendSlice(wasm_allocator, ",\"column\":");
        try Diagnostic.appendInt(json_buf, wasm_allocator, pos.column);
        try json_buf.append(wasm_allocator, '}');
    }
    try json_buf.append(wasm_allocator, ']');
}

/// Serialize a single Diagnostic.Entry to JSON.
fn serializeDiagnosticEntry(json_buf: *std.ArrayListUnmanaged(u8), entry: *const Diagnostic.Entry) Allocator.Error!void {
    try Diagnostic.entryToJson(json_buf, wasm_allocator, entry);
}

fn packValidateResultWithJson(valid: bool, error_count: usize, json: []const u8) ?[*]u8 {
    const out_buf = wasm_allocator.alloc(u8, 12 + json.len) catch return null;
    std.mem.writeInt(u32, out_buf[0..4], if (valid) 1 else 0, .little);
    std.mem.writeInt(u32, out_buf[4..8], @intCast(error_count), .little);
    std.mem.writeInt(u32, out_buf[8..12], @intCast(json.len), .little);
    @memcpy(out_buf[12..][0..json.len], json);
    return out_buf.ptr;
}

/// Reflect WGSL source code (extract bindings, layouts, entry points).
/// Input: pointer to source text + length.
/// Output: pointer to result buffer [u32 len][u8... json_result].
///         Returns null on allocation failure.
export fn wgslender_reflect(source_ptr: [*]const u8, source_len: u32) ?[*]u8 {
    return reflectImpl(source_ptr, source_len) catch return null;
}

fn reflectImpl(source_ptr: [*]const u8, source_len: u32) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    // Tokenize + parse
    const tokens = Lexer.tokenize(wasm_allocator, source) catch return null;
    var parser = Parser.init(wasm_allocator, source, tokens) catch return null;
    const module = parser.parse() catch {
        // Return empty result with error
        return try packReflectError(parser.errors.items);
    };

    // Check for parse errors (parser may recover without throwing)
    if (parser.errors.items.len > 0) {
        return try packReflectError(parser.errors.items);
    }

    // Reflect
    const result = try Reflect.reflect(wasm_allocator, module);

    // Serialize to JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    try result.toJson(&json_buf, wasm_allocator);

    const json = json_buf.items;
    const out_buf = try wasm_allocator.alloc(u8, 4 + json.len);
    std.mem.writeInt(u32, out_buf[0..4], @intCast(json.len), .little);
    @memcpy(out_buf[4..][0..json.len], json);

    return out_buf.ptr;
}

/// Minify and reflect in a single pass with JSON options and JSON result.
/// Input: source pointer+length, JSON options pointer+length.
/// Output: pointer to [u32 json_len][u8... json] where JSON is
///         {"minify":{...},"reflect":{...}}
///         Returns null on allocation failure.
export fn wgslender_minify_and_reflect_json(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) ?[*]u8 {
    return minifyAndReflectJsonImpl(source_ptr, source_len, opts_ptr, opts_len) catch return null;
}

fn minifyAndReflectJsonImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    const opts_slice = opts_ptr[0..opts_len];
    const config = Config.parseJson(wasm_allocator, opts_slice) catch Config{};
    var options = config.toOptions();

    if (config.source_map) |sm| {
        options.generate_source_map = sm;
    }
    if (config.source_map_sources) |sms| {
        options.source_map_options.include_source = sms;
    }

    const empty_result_json =
        \\{"minify":{"code":"","errors":[{"message":"minification failed"}],
    ++
        \\"originalSize":0,"minifiedSize":0},
    ++
        \\"reflect":{"bindings":[],"structs":{},"entryPoints":[]}}
    ;
    const result = Minifier.minifyAndReflect(wasm_allocator, source, options) catch {
        return packJsonResult(empty_result_json);
    };

    var json_buf: std.ArrayListUnmanaged(u8) = .empty;

    // Minify part
    try json_buf.appendSlice(wasm_allocator, "{\"minify\":{\"code\":\"");
    try Diagnostic.appendJsonEscaped(&json_buf, wasm_allocator, result.minify.code);
    try json_buf.appendSlice(wasm_allocator, "\",\"errors\":[");
    for (result.minify.errors, 0..) |err, i| {
        if (i > 0) try json_buf.append(wasm_allocator, ',');
        try json_buf.appendSlice(wasm_allocator, "{\"message\":\"");
        try Diagnostic.appendJsonEscaped(&json_buf, wasm_allocator, err.message);
        try json_buf.appendSlice(wasm_allocator, "\"}");
    }
    try json_buf.appendSlice(wasm_allocator, "],\"originalSize\":");
    try Diagnostic.appendInt(&json_buf, wasm_allocator, result.minify.original_size);
    try json_buf.appendSlice(wasm_allocator, ",\"minifiedSize\":");
    try Diagnostic.appendInt(&json_buf, wasm_allocator, result.minify.minified_size);
    if (result.minify.source_map) |sm| {
        try json_buf.appendSlice(wasm_allocator, ",\"sourceMap\":");
        try sm.toJson(&json_buf, wasm_allocator);
    }
    try json_buf.appendSlice(wasm_allocator, "},\"reflect\":");

    // Reflect part
    try result.reflect.toJson(&json_buf, wasm_allocator);

    try json_buf.append(wasm_allocator, '}');

    return packJsonResult(json_buf.items);
}

// =========================================================================
// Edits (rename / findReferences)
// =========================================================================

const Edits = wgslender.Edits;

/// Find all references to the symbol under `offset` in source.
///
/// Input: source bytes + length, byte offset, include_declaration (0/1).
/// Output: [u32 json_len][u8 json] where JSON is
///   {"references":[{"start":N,"end":N,"isWrite":bool},...]}
/// or, on parse failure or when no symbol is under the offset,
///   {"references":[],"error":"..."} / {"references":[]}.
/// Returns null on allocation failure.
export fn wgslender_find_references(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    include_declaration: u32,
) ?[*]u8 {
    return findReferencesImpl(source_ptr, source_len, offset, include_declaration != 0) catch return null;
}

fn findReferencesImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    include_declaration: bool,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packJsonResultAlloc(
        "{\"references\":[],\"error\":\"parse error\"}",
    );

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return try packJsonResultAlloc("{\"references\":[]}");

    const refs = try Edits.findReferences(wasm_allocator, module, target, include_declaration);
    defer wasm_allocator.free(refs);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(wasm_allocator);
    try json.appendSlice(wasm_allocator, "{\"references\":[");
    for (refs, 0..) |r, i| {
        if (i > 0) try json.append(wasm_allocator, ',');
        try json.appendSlice(wasm_allocator, "{\"start\":");
        try Diagnostic.appendInt(&json, wasm_allocator, r.start);
        try json.appendSlice(wasm_allocator, ",\"end\":");
        try Diagnostic.appendInt(&json, wasm_allocator, r.end);
        try json.appendSlice(wasm_allocator, ",\"isWrite\":");
        try json.appendSlice(wasm_allocator, if (r.is_write) "true" else "false");
        try json.append(wasm_allocator, '}');
    }
    try json.appendSlice(wasm_allocator, "]}");
    return packJsonResult(json.items);
}

/// Compute the text edits that rename the symbol under `offset` to
/// `new_name`. Offsets in the returned edits are byte offsets against
/// the input source (not the sentinel-copy).
///
/// Output JSON:
///   {"edits":[{"start":N,"end":N,"newText":"..."}, ...]}
/// on success, or with an additional "error" field on failure:
///   {"edits":[],"error":"invalid identifier" | "symbol not found" | "parse error"}
///
/// Returns null on allocation failure.
export fn wgslender_rename(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) ?[*]u8 {
    return renameImpl(source_ptr, source_len, offset, new_name_ptr, new_name_len) catch return null;
}

fn renameImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);
    const new_name = new_name_ptr[0..new_name_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return try packJsonResultAlloc("{\"edits\":[],\"error\":\"invalid identifier\"}");
    }

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packJsonResultAlloc(
        "{\"edits\":[],\"error\":\"parse error\"}",
    );

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return try packJsonResultAlloc(
        "{\"edits\":[],\"error\":\"symbol not found\"}",
    );

    const edits = (try Edits.renameEdits(wasm_allocator, module, target, new_name)) orelse
        return try packJsonResultAlloc("{\"edits\":[],\"error\":\"invalid identifier\"}");
    defer wasm_allocator.free(edits);

    return try packEditsJson(edits, new_name);
}

/// Rename-and-apply: compute edits for renaming the symbol at `offset`
/// to `new_name` and return the rewritten source plus the edits.
///
/// Output JSON:
///   {"source":"...","edits":[...],"ok":true}
/// or on failure:
///   {"source":"<original>","edits":[],"ok":false,"error":"..."}
///
/// The `source` field is always present — callers can use it as a drop-in
/// replacement for the input text whether the rename succeeded or not.
/// Returns null on allocation failure.
export fn wgslender_rename_apply(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) ?[*]u8 {
    return renameApplyImpl(source_ptr, source_len, offset, new_name_ptr, new_name_len) catch return null;
}

fn renameApplyImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) Allocator.Error!?[*]u8 {
    const source_copy = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source_copy.ptr[0 .. source_copy.len + 1]);
    const new_name = new_name_ptr[0..new_name_len];

    const original_bytes = source_ptr[0..source_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return try packRenameApplyFailure(original_bytes, "invalid identifier");
    }

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source_copy, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packRenameApplyFailure(original_bytes, "parse error");

    const target = Edits.symbolAtOffset(module, offset);
    if (!target.isValid()) return try packRenameApplyFailure(original_bytes, "symbol not found");

    const edits = (try Edits.renameEdits(wasm_allocator, module, target, new_name)) orelse
        return try packRenameApplyFailure(original_bytes, "invalid identifier");
    defer wasm_allocator.free(edits);

    const rewritten = try Edits.applyEdits(wasm_allocator, original_bytes, edits);
    defer wasm_allocator.free(rewritten);

    return try packRenameApplySuccess(rewritten, edits, new_name);
}

fn packEditsJson(edits: []const Edits.TextEdit, new_name: []const u8) Allocator.Error!?[*]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(wasm_allocator);
    try json.appendSlice(wasm_allocator, "{\"edits\":[");
    for (edits, 0..) |e, i| {
        if (i > 0) try json.append(wasm_allocator, ',');
        try writeEditJson(&json, e, new_name);
    }
    try json.appendSlice(wasm_allocator, "]}");
    return packJsonResult(json.items);
}

fn writeEditJson(
    json: *std.ArrayListUnmanaged(u8),
    edit: Edits.TextEdit,
    new_text: []const u8,
) Allocator.Error!void {
    try json.appendSlice(wasm_allocator, "{\"start\":");
    try Diagnostic.appendInt(json, wasm_allocator, edit.start);
    try json.appendSlice(wasm_allocator, ",\"end\":");
    try Diagnostic.appendInt(json, wasm_allocator, edit.end);
    try json.appendSlice(wasm_allocator, ",\"newText\":\"");
    try Diagnostic.appendJsonEscaped(json, wasm_allocator, new_text);
    try json.appendSlice(wasm_allocator, "\"}");
}

fn packRenameApplySuccess(
    rewritten: []const u8,
    edits: []const Edits.TextEdit,
    new_name: []const u8,
) Allocator.Error!?[*]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(wasm_allocator);
    try json.appendSlice(wasm_allocator, "{\"ok\":true,\"source\":\"");
    try Diagnostic.appendJsonEscaped(&json, wasm_allocator, rewritten);
    try json.appendSlice(wasm_allocator, "\",\"edits\":[");
    for (edits, 0..) |e, i| {
        if (i > 0) try json.append(wasm_allocator, ',');
        try writeEditJson(&json, e, new_name);
    }
    try json.appendSlice(wasm_allocator, "]}");
    return packJsonResult(json.items);
}

fn packRenameApplyFailure(original: []const u8, msg: []const u8) Allocator.Error!?[*]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(wasm_allocator);
    try json.appendSlice(wasm_allocator, "{\"ok\":false,\"source\":\"");
    try Diagnostic.appendJsonEscaped(&json, wasm_allocator, original);
    try json.appendSlice(wasm_allocator, "\",\"edits\":[],\"error\":\"");
    try Diagnostic.appendJsonEscaped(&json, wasm_allocator, msg);
    try json.appendSlice(wasm_allocator, "\"}");
    return packJsonResult(json.items);
}

fn packJsonResultAlloc(comptime literal: []const u8) Allocator.Error!?[*]u8 {
    return packJsonResult(literal);
}

// =========================================================================
// Stable IDs (reparse-stable symbol identifiers)
// =========================================================================

const StableIdMod = wgslender.StableId;

/// Resolve the byte offset to a reparse-stable identifier.
///
/// Output JSON:
///   {"stableId":"v1:fn:main/block#0/let:x"}
/// or, on parse failure or no symbol under the offset:
///   {"stableId":null} (possibly with "error" field)
export fn wgslender_stable_id_at_offset(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
) ?[*]u8 {
    return stableIdAtOffsetImpl(source_ptr, source_len, offset) catch return null;
}

fn stableIdAtOffsetImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packJsonResultAlloc(
        "{\"stableId\":null,\"error\":\"parse error\"}",
    );

    var sid_arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer sid_arena.deinit();

    const maybe_id = StableIdMod.stableIdAtOffset(sid_arena.allocator(), module, offset) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IdTooLong => return try packJsonResultAlloc("{\"stableId\":null,\"error\":\"id too long\"}"),
    };
    if (maybe_id) |id| {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(wasm_allocator);
        try json.appendSlice(wasm_allocator, "{\"stableId\":\"");
        try Diagnostic.appendJsonEscaped(&json, wasm_allocator, id.bytes);
        try json.appendSlice(wasm_allocator, "\"}");
        return packJsonResult(json.items);
    }
    return try packJsonResultAlloc("{\"stableId\":null}");
}

/// Resolve a stable ID to the declaration byte range in the current source.
///
/// Output JSON:
///   {"start":N,"end":N}
/// or on failure:
///   {"start":null,"end":null,"error":"..."}
export fn wgslender_locate_stable_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) ?[*]u8 {
    return locateStableIdImpl(source_ptr, source_len, id_ptr, id_len) catch return null;
}

fn locateStableIdImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);

    const id_bytes = id_ptr[0..id_len];

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packJsonResultAlloc(
        "{\"start\":null,\"end\":null,\"error\":\"parse error\"}",
    );

    if (StableIdMod.locateStableId(module, id_bytes)) |range| {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(wasm_allocator);
        try json.appendSlice(wasm_allocator, "{\"start\":");
        try Diagnostic.appendInt(&json, wasm_allocator, range.start);
        try json.appendSlice(wasm_allocator, ",\"end\":");
        try Diagnostic.appendInt(&json, wasm_allocator, range.end);
        try json.appendSlice(wasm_allocator, "}");
        return packJsonResult(json.items);
    }
    return try packJsonResultAlloc("{\"start\":null,\"end\":null,\"error\":\"not found\"}");
}

/// Compute rename edits against a symbol identified by stable ID.
/// Same output shape as `wgslender_rename`.
export fn wgslender_rename_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) ?[*]u8 {
    return renameByIdImpl(
        source_ptr,
        source_len,
        id_ptr,
        id_len,
        new_name_ptr,
        new_name_len,
    ) catch return null;
}

fn renameByIdImpl(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) Allocator.Error!?[*]u8 {
    const source = makeSentinelSource(source_ptr, source_len) orelse return null;
    defer wasm_allocator.free(source.ptr[0 .. source.len + 1]);
    const id_bytes = id_ptr[0..id_len];
    const new_name = new_name_ptr[0..new_name_len];

    if (!Edits.isValidWgslIdentifier(new_name)) {
        return try packJsonResultAlloc("{\"edits\":[],\"error\":\"invalid identifier\"}");
    }

    var analysis = wgslender.analyzeWithOptions(wasm_allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer analysis.deinit(wasm_allocator);

    const module = analysis.module orelse return try packJsonResultAlloc(
        "{\"edits\":[],\"error\":\"parse error\"}",
    );

    const target = StableIdMod.symbolForStableId(module, id_bytes);
    if (!target.isValid()) return try packJsonResultAlloc(
        "{\"edits\":[],\"error\":\"symbol not found\"}",
    );

    const edits = (try Edits.renameEdits(wasm_allocator, module, target, new_name)) orelse
        return try packJsonResultAlloc("{\"edits\":[],\"error\":\"invalid identifier\"}");
    defer wasm_allocator.free(edits);

    return try packEditsJson(edits, new_name);
}

/// Return the version string.
export fn wgslender_version() [*]const u8 {
    return wgslender.version.ptr;
}

/// Return the version string length.
export fn wgslender_version_len() u32 {
    return wgslender.version.len;
}

fn packReflectError(errors: []const Parser.ParseError) Allocator.Error!?[*]u8 {
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    try json_buf.appendSlice(wasm_allocator, "{\"bindings\":[],\"structs\":{},\"entryPoints\":[],\"errors\":[");
    for (errors, 0..) |err, i| {
        if (i > 0) try json_buf.append(wasm_allocator, ',');
        try json_buf.append(wasm_allocator, '"');
        try Diagnostic.appendJsonEscaped(&json_buf, wasm_allocator, err.message);
        try json_buf.append(wasm_allocator, '"');
    }
    try json_buf.appendSlice(wasm_allocator, "]}");
    return packJsonResult(json_buf.items);
}

// =========================================================================
// Helpers
// =========================================================================

/// Create a sentinel-terminated copy of source. Caller must free the returned
/// pointer (of length source_len + 1) with wasm_allocator.
fn makeSentinelSource(source_ptr: [*]const u8, source_len: u32) ?[:0]const u8 {
    const buf = wasm_allocator.alloc(u8, source_len + 1) catch return null;
    @memcpy(buf[0..source_len], source_ptr[0..source_len]);
    buf[source_len] = 0;
    return buf[0..source_len :0];
}

fn packJsonResult(json: []const u8) ?[*]u8 {
    const out_buf = wasm_allocator.alloc(u8, 4 + json.len) catch return null;
    std.mem.writeInt(u32, out_buf[0..4], @intCast(json.len), .little);
    @memcpy(out_buf[4..][0..json.len], json);
    return out_buf.ptr;
}
