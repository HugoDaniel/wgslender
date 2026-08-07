//! `computeWorkspaceSymbols` — the cmd-T "search symbols by name across
//! the workspace" feature. Collects module-scope declarations (plus
//! struct fields, qualified by their container) from every open
//! document, filtered by the LSP-sanctioned relaxed match: query
//! characters must appear in order, case-insensitively. Results are
//! sorted by (uri, position) so responses are deterministic across the
//! hash-map iteration order of the document store.

const std = @import("std");
const Handler = @import("Handler");

const doc_a: [:0]const u8 =
    \\struct Particle { pos: vec4f, vel: vec4f }
    \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
    \\fn integrate(p: Particle) -> Particle { let scale = 1.0; return p; }
;

const doc_b: [:0]const u8 =
    \\const MAX_STEPS: u32 = 64u;
    \\alias Color = vec4f;
    \\override brightness: f32 = 1.0;
;

fn setup() !*Handler {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    errdefer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }
    try handler.openDocument("test://a.wgsl", doc_a, 1);
    try handler.openDocument("test://b.wgsl", doc_b, 1);
    return handler;
}

fn teardown(handler: *Handler) void {
    handler.deinit();
    std.testing.allocator.destroy(handler);
}

fn findByName(syms: []const Handler.WorkspaceSymbolInfo, name: []const u8) ?Handler.WorkspaceSymbolInfo {
    for (syms) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "workspace symbols: empty query returns every module-scope symbol from every document" {
    const handler = try setup();
    defer teardown(handler);

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);

    // doc_a: Particle, pos, vel, particles, integrate — doc_b: MAX_STEPS, Color, brightness
    try std.testing.expectEqual(@as(usize, 8), syms.len);

    const particle = findByName(syms, "Particle") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Handler.SymbolKind.struct_type, particle.kind);
    try std.testing.expectEqualStrings("test://a.wgsl", particle.uri);
    try std.testing.expectEqual(@as(u32, 0), particle.range.start.line);
    try std.testing.expectEqual(@as(u32, 7), particle.range.start.character);

    const max_steps = findByName(syms, "MAX_STEPS") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Handler.SymbolKind.constant, max_steps.kind);
    try std.testing.expectEqualStrings("test://b.wgsl", max_steps.uri);

    const color = findByName(syms, "Color") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Handler.SymbolKind.type_alias, color.kind);

    const brightness = findByName(syms, "brightness") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Handler.SymbolKind.override, brightness.kind);
}

test "workspace symbols: struct fields carry their container name" {
    const handler = try setup();
    defer teardown(handler);

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);

    const pos = findByName(syms, "pos") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Handler.SymbolKind.field, pos.kind);
    try std.testing.expectEqualStrings("Particle", pos.container_name);

    const particle = findByName(syms, "Particle") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", particle.container_name);
}

test "workspace symbols: function locals are not indexed" {
    const handler = try setup();
    defer teardown(handler);

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);

    try std.testing.expect(findByName(syms, "scale") == null);
    try std.testing.expect(findByName(syms, "p") == null);
}

test "workspace symbols: query matches case-insensitively in order" {
    const handler = try setup();
    defer teardown(handler);

    // "itg" is a subsequence of "integrate" (i·n·t·e·g·rate) and of
    // nothing else in either document.
    const syms = try handler.computeWorkspaceSymbols("ITG");
    defer handler.gpa.free(syms);

    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqualStrings("integrate", syms[0].name);
    try std.testing.expectEqual(@as(u32, 2), syms[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 3), syms[0].range.start.character);
}

test "workspace symbols: query characters must appear in order" {
    const handler = try setup();
    defer teardown(handler);

    // "integrate" contains t, g, and i — but its only i comes before the
    // g, so "tgi" is not a subsequence. A bag-of-characters matcher
    // would wrongly return it.
    const syms = try handler.computeWorkspaceSymbols("tgi");
    defer handler.gpa.free(syms);
    try std.testing.expectEqual(@as(usize, 0), syms.len);
}

test "workspace symbols: no match returns empty" {
    const handler = try setup();
    defer teardown(handler);

    const syms = try handler.computeWorkspaceSymbols("zzzz");
    defer handler.gpa.free(syms);
    try std.testing.expectEqual(@as(usize, 0), syms.len);
}

test "workspace symbols: results are sorted by uri then position" {
    const handler = try setup();
    defer teardown(handler);

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);

    var i: usize = 1;
    while (i < syms.len) : (i += 1) {
        const prev = syms[i - 1];
        const cur = syms[i];
        const uri_order = std.mem.order(u8, prev.uri, cur.uri);
        try std.testing.expect(uri_order != .gt);
        if (uri_order == .eq) {
            try std.testing.expect(prev.range.start.line < cur.range.start.line or
                (prev.range.start.line == cur.range.start.line and
                    prev.range.start.character <= cur.range.start.character));
        }
    }
}

test "workspace symbols: a document that fails to parse contributes nothing" {
    const handler = try setup();
    defer teardown(handler);
    try handler.openDocument("test://broken.wgsl", "struct {{{", 1);

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);

    // The two healthy documents still answer.
    try std.testing.expectEqual(@as(usize, 8), syms.len);
    for (syms) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.uri, "test://broken.wgsl"));
    }
}

test "workspace symbols: no open documents returns empty" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const syms = try handler.computeWorkspaceSymbols("");
    defer handler.gpa.free(syms);
    try std.testing.expectEqual(@as(usize, 0), syms.len);
}
