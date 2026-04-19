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

test "F-PROP: every literal swap leaves errors equal to a parseFull oracle" {
    // Property test for the error-fixup path. A no-op literal swap
    // (e.g. `0` → `9`) is a kind-stable hot edit on a literal_expr
    // anchor. Whatever errors the source had before must shift cleanly
    // (or stay put) and equal what a fresh full parse would produce.
    const gpa = std.testing.allocator;

    const FixupCheck = struct {
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        steps: u32 = 0,

        fn onLiteral(self: *@This(), lit_start: u32, lit_end: u32) !void {
            self.steps += 1;
            var base = try Incremental.parseFull(self.gpa, self.source);
            defer base.deinit();
            const replacement: []const u8 = switch (self.source[lit_start]) {
                '0', '1', '2', '3', '4' => "9",
                else => "0",
            };
            var upd = try Incremental.reparse(self.gpa, &base, .{
                .start = lit_start,
                .end = lit_start + 1,
                .new_text = replacement,
            });
            defer upd.deinit();
            _ = lit_end;
            try std.testing.expect(upd.reused);

            var oracle = try Incremental.parseFull(self.gpa, upd.source);
            defer oracle.deinit();
            try std.testing.expectEqual(oracle.errors.len, upd.errors.len);
            for (upd.errors, oracle.errors) |g, o| {
                try std.testing.expectEqualStrings(o.code, g.code);
                try std.testing.expectEqual(o.pos, g.pos);
                try std.testing.expectEqual(o.end, g.end);
            }
        }
    };

    // Sources designed so each literal swap exercises a different
    // fixup case: clean (no errors), errors strictly downstream, errors
    // strictly upstream.
    const sources = [_][:0]const u8{
        "fn f() -> i32 { return 0; }",
        "fn f() -> i32 { return 0; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        "fn g() -> i32 { return q; let q: i32 = 1; return q; } fn f() -> i32 { return 0; }",
    };
    for (sources) |s| {
        var check: FixupCheck = .{ .gpa = gpa, .source = s };
        try forEachLiteral(gpa, s, &check, FixupCheck.onLiteral);
        try std.testing.expect(check.steps > 0);
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

test "F5: random local-decl append into a function body always hot-paths" {
    const gpa = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xA99EDCAF);
    const rand = rng.random();

    const shader_bases = [_][:0]const u8{
        "fn f() {}",
        "fn f() { let a = 1; }",
        "fn f() { let a = 1; let b = a + 2; }",
        "fn g() { let x = 1; } fn f() { let a = 1; }",
        "fn f() { if (true) { let z = 1; } }",
    };

    for (shader_bases) |base| {
        var cur = try Incremental.parseFull(gpa, base);
        defer cur.deinit();

        var iter: u32 = 0;
        while (iter < 10) : (iter += 1) {
            // Find a `}` byte at random and insert a complete statement
            // just before it. A decl_stmt append at a compound's close
            // boundary always takes the compound_stmt hot path.
            var candidate_positions: std.ArrayListUnmanaged(u32) = .empty;
            defer candidate_positions.deinit(gpa);
            for (cur.source, 0..) |c, i| {
                if (c == '}') try candidate_positions.append(gpa, @intCast(i));
            }
            if (candidate_positions.items.len == 0) break;

            const pick = rand.intRangeLessThan(usize, 0, candidate_positions.items.len);
            const close_off = candidate_positions.items[pick];

            var buf: [64]u8 = undefined;
            const val = rand.intRangeLessThan(u32, 0, 1000);
            const payload = try std.fmt.bufPrint(&buf, " let tmp_{} = {};", .{ iter, val });

            const next = try Incremental.reparse(gpa, &cur, .{
                .start = close_off,
                .end = close_off,
                .new_text = payload,
            });
            cur.deinit();
            cur = next;
            try std.testing.expect(cur.reused);
        }

        // Final shape must match a fresh full parse. Symbol table is
        // append-only on the Phase 2 compound_stmt hot path, so allow
        // extras in `cur` as long as they are all dead (use_count == 0)
        // and every oracle symbol has a live counterpart.
        var oracle = try Incremental.parseFull(gpa, cur.source);
        defer oracle.deinit();
        try std.testing.expectEqual(
            oracle.module.declarations.items.len,
            cur.module.declarations.items.len,
        );
        try std.testing.expect(cur.module.symbols.items.len >= oracle.module.symbols.items.len);
        const oracle_live = countLive(oracle.module);
        const cur_live = countLive(cur.module);
        try std.testing.expectEqual(oracle_live, cur_live);
    }
}

fn countLive(m: *const wgslender.Ast.Module) usize {
    var n: usize = 0;
    for (m.symbols.items) |s| if (s.use_count > 0) {
        n += 1;
    };
    return n;
}
