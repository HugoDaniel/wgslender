//! Parity goldens for the plain `format(source)` export.
//!
//! The LSP handler's `textDocument/formatting` and
//! `api_json.formatToJson` (the body behind the `wgslender_format_json`
//! WASM export) must produce byte-identical text — one printer, two
//! envelopes. Formatting must also be idempotent, and a malformed document
//! must come back as the input with `error` set while the LSP handler keeps
//! refusing it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgslender = @import("wgslender");
const Handler = @import("Handler");
const fixtures = @import("formatting_fixtures.zig");

const testdata = [_][:0]const u8{
    @embedFile("testdata/basic_vert.wgsl"),
    @embedFile("testdata/fullscreen_quad.wgsl"),
    @embedFile("testdata/trailing_comma_fn_params.wgsl"),
};

/// Run the LSP handler's formatter. Non-null text is owned by the caller.
fn lspFormat(alloc: Allocator, source: [:0]const u8) !?[]const u8 {
    const handler = try alloc.create(Handler);
    defer alloc.destroy(handler);
    handler.* = Handler.init(alloc);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", source, 1);
    const edit = try handler.computeFormatting("test://file.wgsl");
    return if (edit) |e| e.new_text else null;
}

/// The `code` field of the `formatToJson` envelope. `alloc` must be an
/// arena-style allocator: the query layer is documented to leak
/// intermediates into its caller's arena.
fn exportedFormat(alloc: Allocator, source: [:0]const u8) ![]const u8 {
    const json = try wgslender.api_json.formatToJson(alloc, source);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    return alloc.dupe(u8, parsed.value.object.get("code").?.string);
}

fn expectIdempotent(alloc: Allocator, source: [:0]const u8) !void {
    const once = try exportedFormat(alloc, source);
    const once_z = try alloc.dupeZ(u8, once);
    const twice = try exportedFormat(alloc, once_z);
    try std.testing.expectEqualStrings(once, twice);
}

test "format: byte-identical to LSP formatting over the shared fixtures" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    for (fixtures.clean) |source| {
        const lsp = try lspFormat(a, source);
        try std.testing.expect(lsp != null);
        defer a.free(lsp.?);
        const exported = try exportedFormat(aa, source);
        try std.testing.expectEqualStrings(lsp.?, exported);
    }
}

test "format: byte-identical to LSP formatting over real testdata shaders" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    for (testdata) |source| {
        const lsp = try lspFormat(a, source);
        try std.testing.expect(lsp != null);
        defer a.free(lsp.?);
        const exported = try exportedFormat(aa, source);
        try std.testing.expectEqualStrings(lsp.?, exported);
    }
}

test "format: idempotent over the shared fixtures and testdata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    for (fixtures.clean) |source| try expectIdempotent(aa, source);
    for (testdata) |source| try expectIdempotent(aa, source);
}

test "format: parse failure keeps the input and sets error; LSP refuses" {
    const a = std.testing.allocator;
    const lsp = try lspFormat(a, fixtures.parse_error);
    try std.testing.expect(lsp == null);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const json = try wgslender.api_json.formatToJson(aa, fixtures.parse_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        fixtures.parse_error,
        parsed.value.object.get("code").?.string,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        parsed.value.object.get("error").?.string,
        "parse errors: ",
    ));
}
