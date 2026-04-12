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
// Version / Free
// =========================================================================

/// Return the version string and length.
export fn wgslender_version_c(len: *u32) [*]const u8 {
    len.* = wgslender.version.len;
    return wgslender.version.ptr;
}
