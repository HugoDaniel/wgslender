//! WASM entry point for wgslender.
//!
//! Each export is a thin shell over `api_json.zig`: open one arena over
//! `wasm_allocator`, run the operation, pack the result into the per-op
//! envelope (allocated directly from `wasm_allocator` so it survives the
//! arena teardown), tear the arena down, return the raw pointer.
//!
//! The JS side reads the envelope using `wasm.memory.buffer` plus
//! `wgslender_alloc` / `wgslender_dealloc` for ownership transfer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgslender = @import("root.zig");
const Minifier = @import("Minifier.zig");
const api_json = @import("api_json.zig");

const wasm_allocator = std.heap.wasm_allocator;

// =========================================================================
// Option flags (flags-based minify, kept for backward compatibility)
// =========================================================================

const OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
const OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
const OPT_MINIFY_SYNTAX: u32 = 1 << 2;
const OPT_TREE_SHAKING: u32 = 1 << 3;
const OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
const OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

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
// Memory transfer (JS-owned writes; wgslender-owned reads)
// =========================================================================

/// Allocate a buffer for JS to write into.
export fn wgslender_alloc(len: u32) callconv(.c) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a buffer previously returned by wgslender_alloc or any export.
export fn wgslender_dealloc(ptr: [*]u8, len: u32) callconv(.c) void {
    wasm_allocator.free(ptr[0..len]);
}

// =========================================================================
// Pack helpers — envelopes allocated directly from wasm_allocator
// =========================================================================

fn packLenPrefixed(bytes: []const u8) ?[*]u8 {
    const buf = wasm_allocator.alloc(u8, 4 + bytes.len) catch return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(bytes.len), .little);
    @memcpy(buf[4..][0..bytes.len], bytes);
    return buf.ptr;
}

fn packValidate(valid: bool, error_count: u32, json: []const u8) ?[*]u8 {
    const buf = wasm_allocator.alloc(u8, 12 + json.len) catch return null;
    std.mem.writeInt(u32, buf[0..4], if (valid) 1 else 0, .little);
    std.mem.writeInt(u32, buf[4..8], error_count, .little);
    std.mem.writeInt(u32, buf[8..12], @intCast(json.len), .little);
    @memcpy(buf[12..][0..json.len], json);
    return buf.ptr;
}

fn packCompile(wasm_bytes: []const u8, original_size: u32, errors_json: []const u8) ?[*]u8 {
    const total: u32 = @intCast(12 + wasm_bytes.len + errors_json.len);
    const buf = wasm_allocator.alloc(u8, total) catch return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(wasm_bytes.len), .little);
    std.mem.writeInt(u32, buf[4..8], original_size, .little);
    std.mem.writeInt(u32, buf[8..12], @intCast(errors_json.len), .little);
    @memcpy(buf[12..][0..wasm_bytes.len], wasm_bytes);
    @memcpy(buf[12 + wasm_bytes.len ..][0..errors_json.len], errors_json);
    return buf.ptr;
}

fn packLint(error_count: u32, warning_count: u32, json: []const u8) ?[*]u8 {
    const buf = wasm_allocator.alloc(u8, 12 + json.len) catch return null;
    std.mem.writeInt(u32, buf[0..4], error_count, .little);
    std.mem.writeInt(u32, buf[4..8], warning_count, .little);
    std.mem.writeInt(u32, buf[8..12], @intCast(json.len), .little);
    @memcpy(buf[12..][0..json.len], json);
    return buf.ptr;
}

fn packLintFix(fixed: []const u8, error_count: u32, warning_count: u32, json: []const u8) ?[*]u8 {
    const total: usize = 16 + fixed.len + json.len;
    const buf = wasm_allocator.alloc(u8, total) catch return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(fixed.len), .little);
    std.mem.writeInt(u32, buf[4..8], error_count, .little);
    std.mem.writeInt(u32, buf[8..12], warning_count, .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(json.len), .little);
    @memcpy(buf[16..][0..fixed.len], fixed);
    @memcpy(buf[16 + fixed.len ..][0..json.len], json);
    return buf.ptr;
}

// =========================================================================
// Minify
// =========================================================================

/// Flags-based minify. Output: `[u32 code_len][u8... code]`.
export fn wgslender_minify(source_ptr: [*]const u8, source_len: u32, flags: u32) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const code = api_json.minifyFlagsToBytes(alloc, source, optionsFromFlags(flags)) catch return null;
    return packLenPrefixed(code);
}

/// JSON-options minify. Output: `[u32 json_len][u8... json]`.
export fn wgslender_minify_json(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.minifyJsonToJson(alloc, source, opts_ptr[0..opts_len]) catch return null;
    return packLenPrefixed(json);
}

/// Combined minify+reflect. Output: `[u32 json_len][u8... json]`.
export fn wgslender_minify_and_reflect_json(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.minifyAndReflectJsonToJson(alloc, source, opts_ptr[0..opts_len]) catch return null;
    return packLenPrefixed(json);
}

// =========================================================================
// Validate
// =========================================================================

/// Validate WGSL source. Output: `[u32 valid][u32 error_count][u32 json_len][u8... json]`.
export fn wgslender_validate(source_ptr: [*]const u8, source_len: u32) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const r = api_json.validateBareDiagnosticsToJson(alloc, source) catch return null;
    return packValidate(r.valid, r.error_count, r.json);
}

// =========================================================================
// Reflect
// =========================================================================

/// Reflect WGSL source. Output: `[u32 json_len][u8... json]`.
export fn wgslender_reflect(source_ptr: [*]const u8, source_len: u32) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.reflectToJson(alloc, source) catch return null;
    return packLenPrefixed(json);
}

// =========================================================================
// Compile
// =========================================================================

/// Compile WGSL source to a binary `.wasm` shader.
/// Output: `[u32 wasm_len][u32 original_size][u32 errors_json_len][u8... wasm][u8... errors_json]`.
export fn wgslender_compile(
    source_ptr: [*]const u8,
    source_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const r = api_json.compileToResult(alloc, source, opts_ptr[0..opts_len]) catch return null;
    return packCompile(r.wasm, r.original_size, r.errors_json);
}

// =========================================================================
// Lint
// =========================================================================

/// Lint WGSL. Output: `[u32 error_count][u32 warning_count][u32 json_len][u8... json]`.
export fn wgslender_lint(
    source_ptr: [*]const u8,
    source_len: u32,
    config_ptr: [*]const u8,
    config_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const opts = api_json.parseLintConfig(alloc, config_ptr[0..config_len]) catch return null;
    const r = api_json.lintToResult(alloc, source, opts) catch return null;
    return packLint(r.error_count, r.warning_count, r.json);
}

/// Lint and apply autofixes. Output:
/// `[u32 fixed_len][u32 error_count][u32 warning_count][u32 json_len]`
/// `[u8... fixed][u8... json]`.
export fn wgslender_lint_fix(
    source_ptr: [*]const u8,
    source_len: u32,
    config_ptr: [*]const u8,
    config_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const opts = api_json.parseLintConfig(alloc, config_ptr[0..config_len]) catch return null;
    const r = api_json.lintFixToResult(alloc, source, opts) catch return null;
    return packLintFix(r.fixed, r.error_count, r.warning_count, r.json);
}

// =========================================================================
// Edits — find-references / rename / rename-apply
// =========================================================================

export fn wgslender_find_references(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    include_declaration: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.findReferencesToJson(alloc, source, offset, include_declaration != 0) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_rename(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.renameToJson(alloc, source, offset, new_name_ptr[0..new_name_len]) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_rename_apply(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_copy = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.renameApplyToJson(
        alloc,
        source_copy,
        source_ptr[0..source_len],
        offset,
        new_name_ptr[0..new_name_len],
    ) catch return null;
    return packLenPrefixed(json);
}

// =========================================================================
// Stable IDs
// =========================================================================

export fn wgslender_stable_id_at_offset(
    source_ptr: [*]const u8,
    source_len: u32,
    offset: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.stableIdAtOffsetToJson(alloc, source, offset) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_locate_stable_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.locateStableIdToJson(alloc, source, id_ptr[0..id_len]) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_rename_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_name_ptr: [*]const u8,
    new_name_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.renameByIdToJson(
        alloc,
        source,
        id_ptr[0..id_len],
        new_name_ptr[0..new_name_len],
    ) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_locate_declaration(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.locateDeclarationToJson(alloc, source, id_ptr[0..id_len]) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_locate_type(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.locateTypeToJson(alloc, source, id_ptr[0..id_len]) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_remove_declaration_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.removeDeclarationByIdToJson(alloc, source, id_ptr[0..id_len]) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_remove_declaration_apply_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_copy = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.removeDeclarationApplyByIdToJson(
        alloc,
        source_copy,
        source_ptr[0..source_len],
        id_ptr[0..id_len],
    ) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_change_type_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_type_ptr: [*]const u8,
    new_type_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.changeTypeByIdToJson(
        alloc,
        source,
        id_ptr[0..id_len],
        new_type_ptr[0..new_type_len],
    ) catch return null;
    return packLenPrefixed(json);
}

export fn wgslender_change_type_apply_by_id(
    source_ptr: [*]const u8,
    source_len: u32,
    id_ptr: [*]const u8,
    id_len: u32,
    new_type_ptr: [*]const u8,
    new_type_len: u32,
) callconv(.c) ?[*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_copy = api_json.makeSentinelSource(alloc, source_ptr[0..source_len]) catch return null;
    const json = api_json.changeTypeApplyByIdToJson(
        alloc,
        source_copy,
        source_ptr[0..source_len],
        id_ptr[0..id_len],
        new_type_ptr[0..new_type_len],
    ) catch return null;
    return packLenPrefixed(json);
}

// =========================================================================
// Version
// =========================================================================

export fn wgslender_version() callconv(.c) [*]const u8 {
    return wgslender.version.ptr;
}

export fn wgslender_version_len() callconv(.c) u32 {
    return wgslender.version.len;
}
