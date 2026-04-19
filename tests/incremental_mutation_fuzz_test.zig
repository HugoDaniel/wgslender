//! Targeted fuzz / corpus tests that stress the symbol-free hot path
//! in `Incremental.reparse` (the `reused = true` path). The existing
//! `incremental_fuzz_test.zig` already verifies byte-correctness via a
//! `parseFull` oracle — these tests add two things:
//!
//! 1. **Hot-path coverage** — a sweep that edits every literal token in
//!    a set of realistic shaders and asserts `reused == true`.
//! 2. **Symbol-table stability** — on any reused-path result, every
//!    `SymbolIndex` that existed before the edit still refers to a
//!    symbol with the same `original_name` + `kind`.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const Lexer = wgslender.Lexer;

const bases = [_][:0]const u8{
    "const pi = 3.14;\nfn area(r: f32) -> f32 { return pi * r * r; }",
    "@compute @workgroup_size(8)\nfn main() { var x: u32 = 0u; x = x + 1u; }",
    "fn step3(a: f32, b: f32) -> f32 { if (a < b) { return 0.0; } return 1.0; }",
};

/// Enumerate all integer / float literal token byte ranges in `source`.
fn forEachLiteral(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), u32, u32) anyerror!void,
) !void {
    var toks = try Lexer.tokenizeAll(gpa, source);
    defer toks.deinit(gpa);
    const tags = toks.items(.tag);
    const starts = toks.items(.start);
    const ends = toks.items(.end);
    for (tags, 0..) |t, i| {
        if (t != .int_literal and t != .float_literal) continue;
        try callback(ctx, starts[i], ends[i]);
    }
}

test "F1: every literal edit reaches the hot path (reused = true)" {
    const gpa = std.testing.allocator;

    const Tally = struct {
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        hot: u32 = 0,
        total: u32 = 0,

        fn onLiteral(self: *@This(), lit_start: u32, lit_end: u32) !void {
            self.total += 1;
            var base = try Incremental.parseFull(self.gpa, self.source);
            defer base.deinit();
            // Swap the digit to a different digit keeping length constant
            // so the anchor stays a literal_expr of the same kind.
            const replacement: []const u8 = switch (self.source[lit_start]) {
                '0', '1', '2', '3', '4' => "9",
                else => "0",
            };
            var upd = try Incremental.reparse(self.gpa, &base, .{
                .start = lit_start,
                .end = lit_start + 1, // single digit
                .new_text = replacement,
            });
            defer upd.deinit();
            _ = lit_end;
            if (upd.reused) self.hot += 1;
        }
    };

    for (bases) |base| {
        var tally: Tally = .{ .gpa = gpa, .source = base };
        try forEachLiteral(gpa, base, &tally, Tally.onLiteral);
        // Every single-digit rewrite lands on a literal_expr anchor,
        // which is symbol-free — every edit must take the hot path.
        try std.testing.expect(tally.total > 0);
        try std.testing.expectEqual(tally.total, tally.hot);
    }
}

test "F4: reused path preserves symbol indices (same name + kind by index)" {
    const gpa = std.testing.allocator;

    // Pick a base with enough symbols that we can compare.
    const base: [:0]const u8 = "const pi = 3.14;\nfn area(r: f32) -> f32 { return pi * r * r; }";

    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // Snapshot prev symbol identity.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var kinds: std.ArrayListUnmanaged(Ast.Symbol.Kind) = .empty;
    defer kinds.deinit(gpa);
    for (prev.module.symbols.items) |s| {
        try names.append(gpa, try gpa.dupe(u8, s.original_name));
        try kinds.append(gpa, s.kind);
    }

    // Edit "3.14" → "3.15" (literal_expr, symbol-free).
    // byte offset of "3.14" in base = 11; length 4.
    const lit_start: u32 = @intCast(std.mem.indexOfScalar(u8, base, '3').?);
    var upd = try Incremental.reparse(gpa, &prev, .{
        .start = lit_start,
        .end = lit_start + 4,
        .new_text = "3.15",
    });
    defer upd.deinit();

    try std.testing.expect(upd.reused);
    // Every prev-indexed symbol must match the new one at the same index.
    try std.testing.expectEqual(names.items.len, upd.module.symbols.items.len);
    for (upd.module.symbols.items, 0..) |s, i| {
        try std.testing.expectEqualStrings(names.items[i], s.original_name);
        try std.testing.expectEqual(kinds.items[i], s.kind);
    }
}

// F5 (random single-byte edits) is deliberately omitted: the existing
// `tests/incremental_fuzz_test.zig` already exercises random-edit
// correctness against a `parseFull` oracle, so the hot path is covered
// there transitively. A future session can re-add a targeted variant
// once the splice path has more defensive guardrails in place.
