//! JSON encoders for the editing batch: completion items, signature
//! help, folding ranges, inlay hints, code lens entries, selection
//! ranges, semantic tokens, and document formatting.
//!
//! Reached as `wire.editing.*` via `lsp/wire_root.zig`. The WASM
//! transport drives every helper from `wasm/editing.zig`. Native parity
//! tests reuse them to assert byte-equivalence with the lsp-kit
//! serializer driven by `lspkit/editing.zig`.
//!
//! Pure encoders — no allocation beyond the caller-provided buffer, no
//! Handler ownership, no JSON parsing. Strings inside `Handler.*Info`
//! are borrowed; the caller must keep them alive until the response is
//! written.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const primitives = @import("primitives.zig");

const Diagnostic = wgslender.Diagnostic;

// =========================================================================
// Completion
// =========================================================================

/// LSP `CompletionItemKind` integer table. Mirrors the enum mapping in
/// `lspkit/editing.zig::toLspKitCompletionKind` so the transports cannot
/// drift on the encoding.
pub fn completionKindCode(kind: Handler.CompletionKind) u32 {
    return switch (kind) {
        .variable => 6,
        .function => 3,
        .struct_type => 22,
        .field => 5,
        .keyword => 14,
        .builtin => 3,
        .type_name => 7,
        .attribute => 10,
    };
}

pub fn appendCompletionItem(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    item: Handler.CompletionItem,
) void {
    primitives.appendStr(buf, gpa, "{\"label\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, item.label) catch {};
    primitives.appendStr(buf, gpa, "\",\"kind\":");
    primitives.appendUint(buf, gpa, completionKindCode(item.kind));
    if (item.detail.len > 0) {
        primitives.appendStr(buf, gpa, ",\"detail\":\"");
        Diagnostic.appendJsonEscaped(buf, gpa, item.detail) catch {};
        primitives.appendStr(buf, gpa, "\"");
    }
    buf.append(gpa, '}') catch {};
}

pub fn appendCompletionItems(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    items: []const Handler.CompletionItem,
) void {
    buf.append(gpa, '[') catch return;
    for (items, 0..) |item, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        appendCompletionItem(buf, gpa, item);
    }
    buf.append(gpa, ']') catch {};
}

// =========================================================================
// Signature Help
// =========================================================================

pub fn appendSignatureHelp(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    info: Handler.SignatureInfo,
) void {
    primitives.appendStr(buf, gpa, "{\"signatures\":[{\"label\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, info.label) catch {};
    primitives.appendStr(buf, gpa, "\"");
    if (info.parameters.len > 0) {
        primitives.appendStr(buf, gpa, ",\"parameters\":[");
        for (info.parameters, 0..) |param, i| {
            if (i > 0) buf.append(gpa, ',') catch {};
            primitives.appendStr(buf, gpa, "{\"label\":\"");
            Diagnostic.appendJsonEscaped(buf, gpa, param) catch {};
            primitives.appendStr(buf, gpa, "\"}");
        }
        buf.append(gpa, ']') catch {};
    }
    primitives.appendStr(buf, gpa, "}],\"activeSignature\":0,\"activeParameter\":");
    primitives.appendUint(buf, gpa, info.active_parameter);
    buf.append(gpa, '}') catch {};
}

// =========================================================================
// Folding Ranges
// =========================================================================

pub fn appendFoldingRanges(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    ranges: []const Handler.FoldingRangeInfo,
) void {
    buf.append(gpa, '[') catch return;
    for (ranges, 0..) |r, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        primitives.appendStr(buf, gpa, "{\"startLine\":");
        primitives.appendUint(buf, gpa, r.start_line);
        primitives.appendStr(buf, gpa, ",\"endLine\":");
        primitives.appendUint(buf, gpa, r.end_line);
        primitives.appendStr(buf, gpa, ",\"kind\":\"");
        primitives.appendStr(buf, gpa, if (r.kind == .comment) "comment" else "region");
        primitives.appendStr(buf, gpa, "\"}");
    }
    buf.append(gpa, ']') catch {};
}

// =========================================================================
// Inlay Hints
// =========================================================================

/// LSP `InlayHintKind` integer table. Mirrors the enum mapping in
/// `lspkit/editing.zig::toLspKitInlayHintKind`.
pub fn inlayHintKindCode(kind: @FieldType(Handler.InlayHintInfo, "kind")) u32 {
    return switch (kind) {
        .parameter_hint => 2,
        .type_hint, .const_value_hint, .minify_size => 1,
    };
}

pub fn appendInlayHints(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    uri: []const u8,
    hints: []const Handler.InlayHintInfo,
) void {
    buf.append(gpa, '[') catch return;
    for (hints, 0..) |h, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        primitives.appendStr(buf, gpa, "{\"position\":{\"line\":");
        primitives.appendUint(buf, gpa, h.position.line);
        primitives.appendStr(buf, gpa, ",\"character\":");
        primitives.appendUint(buf, gpa, h.position.character);
        primitives.appendStr(buf, gpa, "},\"label\":");
        if (h.def_range) |dr| {
            primitives.appendStr(buf, gpa, "[{\"value\":\"");
            Diagnostic.appendJsonEscaped(buf, gpa, h.label) catch {};
            primitives.appendStr(buf, gpa, "\",\"location\":{\"uri\":\"");
            Diagnostic.appendJsonEscaped(buf, gpa, uri) catch {};
            primitives.appendStr(buf, gpa, "\",\"range\":");
            primitives.formatRange(buf, gpa, dr);
            primitives.appendStr(buf, gpa, "}}]");
        } else {
            buf.append(gpa, '"') catch {};
            Diagnostic.appendJsonEscaped(buf, gpa, h.label) catch {};
            buf.append(gpa, '"') catch {};
        }
        primitives.appendStr(buf, gpa, ",\"kind\":");
        primitives.appendUint(buf, gpa, inlayHintKindCode(h.kind));
        if (h.tooltip) |t| {
            primitives.appendStr(buf, gpa, ",\"tooltip\":\"");
            Diagnostic.appendJsonEscaped(buf, gpa, t) catch {};
            primitives.appendStr(buf, gpa, "\"");
        }
        buf.append(gpa, '}') catch {};
    }
    buf.append(gpa, ']') catch {};
}

// =========================================================================
// Code Lens
// =========================================================================

pub fn appendCodeLenses(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    lenses: []const Handler.CodeLensInfo,
) void {
    buf.append(gpa, '[') catch return;
    for (lenses, 0..) |l, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        primitives.appendStr(buf, gpa, "{\"range\":");
        primitives.formatRange(buf, gpa, l.range);
        primitives.appendStr(buf, gpa, ",\"command\":{\"title\":\"");
        Diagnostic.appendJsonEscaped(buf, gpa, l.title) catch {};
        primitives.appendStr(buf, gpa, "\",\"command\":\"");
        if (l.command) |c| Diagnostic.appendJsonEscaped(buf, gpa, c) catch {};
        primitives.appendStr(buf, gpa, "\"");
        if (l.arguments) |args| {
            primitives.appendStr(buf, gpa, ",\"arguments\":[");
            for (args, 0..) |arg, j| {
                if (j > 0) buf.append(gpa, ',') catch {};
                switch (arg) {
                    .string => |s| {
                        buf.append(gpa, '"') catch {};
                        Diagnostic.appendJsonEscaped(buf, gpa, s) catch {};
                        buf.append(gpa, '"') catch {};
                    },
                    else => primitives.appendStr(buf, gpa, "null"),
                }
            }
            buf.append(gpa, ']') catch {};
        }
        primitives.appendStr(buf, gpa, "}}");
    }
    buf.append(gpa, ']') catch {};
}

// =========================================================================
// Selection Range (recursive — `parent` shares the same shape)
// =========================================================================

pub fn appendSelectionRange(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    sel: *const Handler.SelectionRangeInfo,
) void {
    primitives.appendStr(buf, gpa, "{\"range\":");
    primitives.formatRange(buf, gpa, sel.range);
    if (sel.parent) |p| {
        primitives.appendStr(buf, gpa, ",\"parent\":");
        appendSelectionRange(buf, gpa, p);
    }
    buf.append(gpa, '}') catch {};
}

/// Fallback shape emitted when `computeSelectionRange` returns `null`
/// for one of the requested positions: a zero-width range at (0, 0)
/// with no parent. Matches the previous wasm/native behavior.
pub fn appendNullSelectionRange(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) void {
    primitives.appendStr(buf, gpa, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
}

// =========================================================================
// Semantic Tokens
// =========================================================================

pub fn appendSemanticTokens(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    data: []const u32,
) void {
    primitives.appendStr(buf, gpa, "{\"data\":[");
    for (data, 0..) |v, i| {
        if (i > 0) buf.append(gpa, ',') catch {};
        primitives.appendUint(buf, gpa, v);
    }
    primitives.appendStr(buf, gpa, "]}");
}

// =========================================================================
// Formatting
// =========================================================================

/// Append `[{"range":…,"newText":"…"}]` for a single document-formatting
/// edit. WGSL formatting always replaces the whole document with one
/// edit, so the wrapping array always has exactly one entry.
pub fn appendFormattingEdit(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    edit: Handler.LspTextEdit,
) void {
    primitives.appendStr(buf, gpa, "[{\"range\":");
    primitives.formatRange(buf, gpa, edit.range);
    primitives.appendStr(buf, gpa, ",\"newText\":\"");
    Diagnostic.appendJsonEscaped(buf, gpa, edit.new_text) catch {};
    primitives.appendStr(buf, gpa, "\"}]");
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

const sample_range: Handler.Range = .{
    .start = .{ .line = 1, .character = 2 },
    .end = .{ .line = 1, .character = 7 },
};

test "appendCompletionItems: kind table + optional detail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const items = [_]Handler.CompletionItem{
        .{ .label = "foo", .kind = .function, .detail = "fn() -> u32" },
        .{ .label = "bar", .kind = .keyword },
    };
    var buf: std.ArrayList(u8) = .empty;
    appendCompletionItems(&buf, aa, &items);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqual(@as(usize, 2), v.array.items.len);
    try testing.expectEqualStrings("foo", v.array.items[0].object.get("label").?.string);
    try testing.expectEqual(@as(i64, 3), v.array.items[0].object.get("kind").?.integer);
    try testing.expectEqualStrings("fn() -> u32", v.array.items[0].object.get("detail").?.string);
    try testing.expect(v.array.items[1].object.get("detail") == null);
    try testing.expectEqual(@as(i64, 14), v.array.items[1].object.get("kind").?.integer);
}

test "appendSignatureHelp: with and without parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const params = [_][]const u8{ "x", "y" };
    var buf: std.ArrayList(u8) = .empty;
    appendSignatureHelp(&buf, aa, .{ .label = "f(x,y)", .parameters = &params, .active_parameter = 1 });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("f(x,y)", v.object.get("signatures").?.array.items[0].object.get("label").?.string);
    try testing.expectEqual(@as(i64, 1), v.object.get("activeParameter").?.integer);
    try testing.expectEqual(@as(usize, 2), v.object.get("signatures").?.array.items[0].object.get("parameters").?.array.items.len);

    var buf2: std.ArrayList(u8) = .empty;
    appendSignatureHelp(&buf2, aa, .{ .label = "g()", .parameters = &.{}, .active_parameter = 0 });
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf2.items, .{});
    try testing.expect(v2.object.get("signatures").?.array.items[0].object.get("parameters") == null);
}

test "appendFoldingRanges: kind string follows enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ranges = [_]Handler.FoldingRangeInfo{
        .{ .start_line = 1, .end_line = 3, .kind = .region },
        .{ .start_line = 5, .end_line = 7, .kind = .comment },
    };
    var buf: std.ArrayList(u8) = .empty;
    appendFoldingRanges(&buf, aa, &ranges);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqualStrings("region", v.array.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("comment", v.array.items[1].object.get("kind").?.string);
}

test "appendInlayHints: def_range null vs set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hints = [_]Handler.InlayHintInfo{
        .{ .position = .{ .line = 1, .character = 2 }, .label = "x", .kind = .type_hint },
        .{ .position = .{ .line = 3, .character = 4 }, .label = "S", .kind = .type_hint, .def_range = sample_range },
    };
    var buf: std.ArrayList(u8) = .empty;
    appendInlayHints(&buf, aa, "test://a.wgsl", &hints);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expect(v.array.items[0].object.get("label").? == .string);
    try testing.expectEqualStrings("x", v.array.items[0].object.get("label").?.string);
    try testing.expect(v.array.items[1].object.get("label").? == .array);
    const part0 = v.array.items[1].object.get("label").?.array.items[0];
    try testing.expectEqualStrings("S", part0.object.get("value").?.string);
    try testing.expectEqualStrings("test://a.wgsl", part0.object.get("location").?.object.get("uri").?.string);
}

test "appendCodeLenses: command + arguments shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const args = [_]std.json.Value{.{ .string = "test://a.wgsl" }};
    const lenses = [_]Handler.CodeLensInfo{.{
        .range = sample_range,
        .title = "1 ref",
        .command = "wgslender.showMinifiedOutput",
        .arguments = @constCast(&args),
    }};
    var buf: std.ArrayList(u8) = .empty;
    appendCodeLenses(&buf, aa, &lenses);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    const cmd = v.array.items[0].object.get("command").?.object;
    try testing.expectEqualStrings("1 ref", cmd.get("title").?.string);
    try testing.expectEqualStrings("wgslender.showMinifiedOutput", cmd.get("command").?.string);
    try testing.expectEqualStrings("test://a.wgsl", cmd.get("arguments").?.array.items[0].string);
}

test "appendSelectionRange: parent recursion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const outer: Handler.SelectionRangeInfo = .{ .range = sample_range, .parent = null };
    const inner: Handler.SelectionRangeInfo = .{
        .range = .{ .start = .{ .line = 1, .character = 3 }, .end = .{ .line = 1, .character = 5 } },
        .parent = &outer,
    };
    var buf: std.ArrayList(u8) = .empty;
    appendSelectionRange(&buf, aa, &inner);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expect(v.object.get("parent") != null);
    try testing.expect(v.object.get("parent").?.object.get("parent") == null);
}

test "appendSemanticTokens: data array passthrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = [_]u32{ 1, 0, 4, 1, 0 };
    var buf: std.ArrayList(u8) = .empty;
    appendSemanticTokens(&buf, aa, &data);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    const arr = v.object.get("data").?.array.items;
    try testing.expectEqual(@as(usize, 5), arr.len);
    try testing.expectEqual(@as(i64, 4), arr[2].integer);
}

test "appendFormattingEdit: single-edit array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    appendFormattingEdit(&buf, aa, .{ .range = sample_range, .new_text = "fn main(){}" });

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, buf.items, .{});
    try testing.expectEqual(@as(usize, 1), v.array.items.len);
    try testing.expectEqualStrings("fn main(){}", v.array.items[0].object.get("newText").?.string);
}
