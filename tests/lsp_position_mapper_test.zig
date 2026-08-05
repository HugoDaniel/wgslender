//! Differential tests for `lsp/PositionMapper.zig`.
//!
//! `PositionMapper` replaces the O(source)-per-call linear scans in
//! `Handler.offsetToLspPosition` / `Handler.lspPositionToOffset` with a
//! line-start index plus a within-line scan. The whole point is that the
//! emitted positions do not move, so the gate here is differential: for
//! every byte offset of every corpus source — including the 70 KB
//! `sceneW.wgsl` — the mapper must agree with the linear helper, `null`s
//! included.
//!
//! Tests live here rather than inline in `PositionMapper.zig` because
//! Zig only collects tests from files reachable through *referenced*
//! decls; a bare `pub const X = @import(…)` re-export in `Handler.zig`
//! is not one (cf. the 18 inline tests in `lsp/handler/code_actions.zig`
//! that compile into no binary).

const std = @import("std");
const Handler = @import("Handler");
const PositionMapper = Handler.PositionMapper;

const emoji = "\xF0\x9F\x8E\x89"; // 🎉 — 4 bytes UTF-8, 2 UTF-16 code units.
const cjk = "\xE4\xB8\xAD"; // 中 — 3 bytes UTF-8, 1 UTF-16 code unit.
const latin1 = "\xC3\xA4"; // ä — 2 bytes UTF-8, 1 UTF-16 code unit.

const scene_w = @embedFile("testdata/sceneW.wgsl");

/// Every case here is valid UTF-8 — malformed sources are covered
/// separately by the "does not scan from byte 0" test, which pins the one
/// place the mapper deliberately differs.
const corpus = [_][]const u8{
    "",
    "\n",
    "\r",
    "\r\n",
    "fn f() {}",
    "fn f() {}\n",
    "a\nb\nc",
    "a\r\nb\r\nc\r\n",
    "a\rb\rc\r",
    "mixed\r\nendings\rhere\nend",
    "\n\n\n",
    "\r\n\r\n",
    // A `\n` immediately following a `\r\n` pair: the second break must
    // still open its own line.
    "a\r\n\nb",
    "// " ++ cjk ++ cjk ++ "\nconst x = 1;",
    "let a = 1; /*" ++ emoji ++ "*/ let b = 2;\n" ++ cjk ++ latin1 ++ "\n",
    "fn f() {\r\n  // a" ++ latin1 ++ cjk ++ emoji ++ "\n  let x = 1;\n}",
    emoji ++ "\n" ++ emoji,
    scene_w,
};

test "PositionMapper.position agrees with offsetToLspPosition at every offset" {
    for (corpus, 0..) |source, case| {
        errdefer std.debug.print("corpus case {d}\n", .{case});
        var pm = try PositionMapper.init(std.testing.allocator, source);
        defer pm.deinit(std.testing.allocator);

        var off: u32 = 0;
        while (off <= source.len) : (off += 1) {
            const expected = Handler.offsetToLspPosition(source, off);
            const actual = pm.position(off);
            errdefer std.debug.print("offset {d}: expected {?} got {?}\n", .{ off, expected, actual });
            try std.testing.expectEqual(expected, actual);
        }
        // Past end-of-source is `null` on both.
        try std.testing.expectEqual(
            Handler.offsetToLspPosition(source, @intCast(source.len + 1)),
            pm.position(@intCast(source.len + 1)),
        );
    }
}

test "PositionMapper.offsetOf agrees with lspPositionToOffset at every position" {
    for (corpus, 0..) |source, case| {
        errdefer std.debug.print("corpus case {d}\n", .{case});
        var pm = try PositionMapper.init(std.testing.allocator, source);
        defer pm.deinit(std.testing.allocator);

        var off: u32 = 0;
        while (off <= source.len) : (off += 1) {
            const pos = Handler.offsetToLspPosition(source, off) orelse continue;
            const expected = Handler.lspPositionToOffset(source, pos);
            const actual = pm.offsetOf(pos);
            errdefer std.debug.print(
                "offset {d} pos {d}:{d}: expected {?} got {?}\n",
                .{ off, pos.line, pos.character, expected, actual },
            );
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "PositionMapper.offsetOf agrees on out-of-domain positions" {
    // Lines past EOF, characters past EOL, and mid-surrogate characters
    // all have documented (and non-obvious) behavior in the linear
    // helper. Sweep a grid well past the ends of each corpus source.
    for (corpus, 0..) |source, case| {
        errdefer std.debug.print("corpus case {d}\n", .{case});
        var pm = try PositionMapper.init(std.testing.allocator, source);
        defer pm.deinit(std.testing.allocator);

        for (0..8) |line| {
            for (0..12) |character| {
                const pos: Handler.Position = .{ .line = @intCast(line), .character = @intCast(character) };
                const expected = Handler.lspPositionToOffset(source, pos);
                const actual = pm.offsetOf(pos);
                errdefer std.debug.print(
                    "pos {d}:{d}: expected {?} got {?}\n",
                    .{ line, character, expected, actual },
                );
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

test "PositionMapper.range agrees with offsetRangeToLspRange" {
    const source = "fn f() {\r\n  let " ++ cjk ++ " = " ++ emoji ++ ";\n}\n";
    var pm = try PositionMapper.init(std.testing.allocator, source);
    defer pm.deinit(std.testing.allocator);

    var start: u32 = 0;
    while (start <= source.len) : (start += 1) {
        var end: u32 = start;
        while (end <= source.len) : (end += 1) {
            try std.testing.expectEqual(
                Handler.offsetRangeToLspRange(source, start, end),
                pm.range(start, end),
            );
        }
    }
}

test "PositionMapper line table: one entry per line break" {
    const cases = [_]struct { source: []const u8, starts: []const u32 }{
        .{ .source = "", .starts = &.{0} },
        .{ .source = "abc", .starts = &.{0} },
        .{ .source = "a\nb", .starts = &.{ 0, 2 } },
        .{ .source = "a\rb", .starts = &.{ 0, 2 } },
        // `\r\n` is ONE line break, so the next line starts after both bytes.
        .{ .source = "a\r\nb", .starts = &.{ 0, 3 } },
        // A trailing break opens a final empty line at `source.len`.
        .{ .source = "a\n", .starts = &.{ 0, 2 } },
        .{ .source = "a\r\n", .starts = &.{ 0, 3 } },
        .{ .source = "\n\n\n", .starts = &.{ 0, 1, 2, 3 } },
        .{ .source = "a\r\n\nb", .starts = &.{ 0, 3, 4 } },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d}: {s}\n", .{ i, c.source });
        var pm = try PositionMapper.init(std.testing.allocator, c.source);
        defer pm.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u32, c.starts, pm.line_starts);
    }
}

test "PositionMapper does not rescan from byte 0" {
    // Complexity pin, and the executable record of the one behavior
    // change: the linear helper scans from byte 0, so a single malformed
    // byte anywhere before the target poisons every later offset (the
    // caller's `orelse` silently drops that token / diagnostic / hint).
    // The mapper only scans within the target line, so an earlier bad
    // byte is invisible. Positions never become *wrong* — the within-line
    // arithmetic is literally the same code — some previously dropped
    // ones now resolve.
    const source = "// \xFF bad lead byte\nl1\nl2\nl3\nl4\nlet x = 1;";
    var pm = try PositionMapper.init(std.testing.allocator, source);
    defer pm.deinit(std.testing.allocator);

    const target: u32 = @intCast(std.mem.indexOf(u8, source, "let x").?);
    try std.testing.expectEqual(@as(?Handler.Position, null), Handler.offsetToLspPosition(source, target));

    const pos = pm.position(target) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 5), pos.line);
    try std.testing.expectEqual(@as(u32, 0), pos.character);
}

test "PositionMapper: malformed byte on the target line still rejects" {
    // Within a line the mapper runs the unchanged scan, so a bad byte
    // *before the offset on the same line* still returns null.
    const source = "ok\n// \xFF bad";
    var pm = try PositionMapper.init(std.testing.allocator, source);
    defer pm.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?Handler.Position, null), pm.position(@intCast(source.len)));
}
