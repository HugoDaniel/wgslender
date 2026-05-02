//! C-ABI static library entry point for wgslender.
//!
//! Each export is a thin shell over `api_json.zig`: open one arena over
//! `page_allocator`, run the operation, copy the result out, tear the
//! arena down. Callers free returned pointers via `wgslender_free_c`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgslender = @import("root.zig");
const Minifier = @import("Minifier.zig");
const Config = @import("Config.zig");
const api_json = @import("api_json.zig");

const page_allocator = std.heap.page_allocator;

// =========================================================================
// Option flags
// =========================================================================

const OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
const OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
const OPT_MINIFY_SYNTAX: u32 = 1 << 2;
const OPT_TREE_SHAKING: u32 = 1 << 3;
const OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
const OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

const OPT_STRICT: u32 = 1 << 0;

fn optionsFromFlags(flags: u32) Minifier.Options {
    return .{
        .minify_whitespace = flags & OPT_MINIFY_WHITESPACE != 0,
        .minify_identifiers = flags & OPT_MINIFY_IDENTIFIERS != 0,
        .minify_syntax = flags & OPT_MINIFY_SYNTAX != 0,
        .tree_shaking = flags & OPT_TREE_SHAKING != 0,
        .mangle_external_bindings = flags & OPT_MANGLE_EXTERNAL != 0,
        .preserve_uniform_struct_types = flags & OPT_PRESERVE_UNIFORM_STRUCTS != 0,
    };
}

// =========================================================================
// Result types
// =========================================================================

pub const WgslenderResult = extern struct {
    code_ptr: ?[*]const u8,
    code_len: u32,
    @"error": bool,
};

pub const WgslenderValidateResult = extern struct {
    valid: bool,
    json_ptr: ?[*]const u8,
    json_len: u32,
    error_count: u32,
};

pub const WgslenderJsonResult = extern struct {
    json_ptr: ?[*]const u8,
    json_len: u32,
    @"error": bool,
};

// =========================================================================
// Helpers
// =========================================================================

fn errorBytesResult() WgslenderResult {
    return .{ .code_ptr = null, .code_len = 0, .@"error" = true };
}

fn errorJsonResult() WgslenderJsonResult {
    return .{ .json_ptr = null, .json_len = 0, .@"error" = true };
}

fn errorValidateResult() WgslenderValidateResult {
    return .{ .valid = false, .json_ptr = null, .json_len = 0, .error_count = 0 };
}

/// Copy `data` into a fresh `page_allocator` slice. Null on OOM.
fn copyOut(data: []const u8) ?[]u8 {
    const out = page_allocator.alloc(u8, data.len) catch return null;
    @memcpy(out, data);
    return out;
}

fn bytesResult(data: []const u8) WgslenderResult {
    const out = copyOut(data) orelse return errorBytesResult();
    return .{ .code_ptr = out.ptr, .code_len = @intCast(out.len), .@"error" = false };
}

fn jsonResult(data: []const u8) WgslenderJsonResult {
    const out = copyOut(data) orelse return errorJsonResult();
    return .{ .json_ptr = out.ptr, .json_len = @intCast(out.len), .@"error" = false };
}

fn validateResult(valid: bool, error_count: u32, data: []const u8) WgslenderValidateResult {
    const out = copyOut(data) orelse return .{
        .valid = valid,
        .json_ptr = null,
        .json_len = 0,
        .error_count = error_count,
    };
    return .{
        .valid = valid,
        .json_ptr = out.ptr,
        .json_len = @intCast(out.len),
        .error_count = error_count,
    };
}

// =========================================================================
// Minify
// =========================================================================

/// Minify WGSL source. Free `code_ptr` with `wgslender_free_c`.
export fn wgslender_minify_c(
    source_ptr: [*]const u8,
    source_len: u32,
    flags: u32,
) callconv(.c) WgslenderResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorBytesResult();
    const code = api_json.minifyFlagsToBytes(alloc, source, optionsFromFlags(flags)) catch
        return errorBytesResult();
    return bytesResult(code);
}

/// Minify WGSL source with JSON options (same keys as `wgslender.json`).
/// Free `code_ptr` with `wgslender_free_c`.
export fn wgslender_minify_json_c(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) WgslenderResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorBytesResult();
    const config = Config.parseJson(alloc, opts_ptr[0..opts_len]) catch Config{};
    const code = api_json.minifyFlagsToBytes(alloc, source, config.toOptions()) catch
        return errorBytesResult();
    return bytesResult(code);
}

// =========================================================================
// Validate
// =========================================================================

/// Validate WGSL source. Free `json_ptr` with `wgslender_free_c`.
export fn wgslender_validate_c(
    source_ptr: [*]const u8,
    source_len: u32,
    flags: u32,
) callconv(.c) WgslenderValidateResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorValidateResult();
    const r = api_json.validateFlagsToJson(alloc, source, flags & OPT_STRICT != 0) catch
        return errorValidateResult();
    return validateResult(r.valid, r.error_count, r.json);
}

// =========================================================================
// Reflect
// =========================================================================

/// Reflect WGSL source. Free `json_ptr` with `wgslender_free_c`.
export fn wgslender_reflect_c(
    source_ptr: [*]const u8,
    source_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.reflectToJson(alloc, source) catch
        return errorJsonResult();
    return jsonResult(json);
}

// =========================================================================
// Edits — find-references / rename / rename-and-apply
// =========================================================================

export fn wgslender_find_references_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    include_declaration: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.findReferencesToJson(alloc, source, offset, include_declaration != 0) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_rename_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.renameToJson(alloc, source, offset, new_name_ptr[0..new_name_len]) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_rename_apply_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_copy = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.renameApplyToJson(
        alloc,
        source_copy,
        source_ptr[0..source_len],
        offset,
        new_name_ptr[0..new_name_len],
    ) catch return errorJsonResult();
    return jsonResult(json);
}

// =========================================================================
// Stable IDs
// =========================================================================

export fn wgslender_stable_id_at_offset_c(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.stableIdAtOffsetToJson(alloc, source, offset) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_locate_stable_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.locateStableIdToJson(alloc, source, id_ptr[0..id_len]) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_rename_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.renameByIdToJson(
        alloc,
        source,
        id_ptr[0..id_len],
        new_name_ptr[0..new_name_len],
    ) catch return errorJsonResult();
    return jsonResult(json);
}

// =========================================================================
// Declaration / type edits (addressed by stable ID)
// =========================================================================

export fn wgslender_locate_declaration_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.locateDeclarationToJson(alloc, source, id_ptr[0..id_len]) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_locate_type_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.locateTypeToJson(alloc, source, id_ptr[0..id_len]) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_remove_declaration_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.removeDeclarationByIdToJson(alloc, source, id_ptr[0..id_len]) catch
        return errorJsonResult();
    return jsonResult(json);
}

export fn wgslender_change_type_by_id_c(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_type_ptr: [*]const u8,
    new_type_len: u32,
) callconv(.c) WgslenderJsonResult {
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch
        return errorJsonResult();
    const json = api_json.changeTypeByIdToJson(
        alloc,
        source,
        id_ptr[0..id_len],
        new_type_ptr[0..new_type_len],
    ) catch return errorJsonResult();
    return jsonResult(json);
}

// =========================================================================
// Free / Version
// =========================================================================

/// Free memory returned by any wgslender_*_c function.
export fn wgslender_free_c(ptr: [*]u8, len: u32) callconv(.c) void {
    page_allocator.free(ptr[0..len]);
}

/// Library version. Do not free the returned pointer.
export fn wgslender_version_c(len: *u32) callconv(.c) [*]const u8 {
    len.* = wgslender.version.len;
    return wgslender.version.ptr;
}
