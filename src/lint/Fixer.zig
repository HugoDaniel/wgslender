//! Autofix application.
//!
//! Rules attach a `Diagnostic.Fix` to their diagnostics. The Fixer
//! collects every fix from a lint result, sorts them by start offset,
//! rejects fixes that overlap an already-accepted fix, and splices the
//! remaining ones into the source.
//!
//! This is the lint-mode equivalent of ESLint's
//! `SourceCodeFixer.applyFixes`. One important property: two fixes that
//! *don't* overlap can both be applied in a single pass. Chained fixes
//! (where applying fix A opens up a new opportunity for fix B) require
//! re-running the linter — the caller owns that loop. We cap at 10
//! passes for convergence.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig");

pub const Result = struct {
    /// Fixed source. Lives on the allocator passed to `apply`.
    fixed: []const u8,
    /// Number of fixes actually applied.
    applied_count: u32 = 0,
    /// Number of fixes dropped because they overlapped an earlier one.
    /// These remain as unfixed diagnostics in the next lint pass.
    conflicted_count: u32 = 0,
};

/// Apply every non-overlapping fix in `entries` to `source`. Returns a
/// newly-allocated string with the fixes applied. Overlapping fixes are
/// dropped silently — the diagnostic they came from stays, unfixed, and
/// a subsequent re-lint will either converge or be dropped by the
/// `run_until_stable` cap.
pub fn apply(
    arena: Allocator,
    source: []const u8,
    entries: []const Diagnostic.Entry,
) Allocator.Error!Result {
    // Collect fixes with their byte ranges. Skip entries without a fix.
    var fixes: std.ArrayListUnmanaged(OrderedFix) = .empty;
    defer fixes.deinit(arena);
    for (entries) |e| {
        const f = e.fix orelse continue;
        try fixes.append(arena, .{
            .start = f.range.start.offset,
            .end = f.range.end.offset,
            .text = f.text,
        });
    }
    if (fixes.items.len == 0) {
        return .{ .fixed = try arena.dupe(u8, source), .applied_count = 0 };
    }

    std.mem.sort(OrderedFix, fixes.items, {}, byStart);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, source.len);
    var cursor: u32 = 0;
    var applied: u32 = 0;
    var conflicted: u32 = 0;
    for (fixes.items) |f| {
        if (f.start < cursor) {
            // Overlaps a prior fix — drop.
            conflicted += 1;
            continue;
        }
        if (f.start > source.len or f.end > source.len) {
            conflicted += 1;
            continue;
        }
        try out.appendSlice(arena, source[cursor..f.start]);
        try out.appendSlice(arena, f.text);
        cursor = f.end;
        applied += 1;
    }
    if (cursor < source.len) {
        try out.appendSlice(arena, source[cursor..]);
    }

    return .{
        .fixed = try out.toOwnedSlice(arena),
        .applied_count = applied,
        .conflicted_count = conflicted,
    };
}

const OrderedFix = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

fn byStart(_: void, a: OrderedFix, b: OrderedFix) bool {
    return a.start < b.start;
}

// =========================================================================
// Tests
// =========================================================================

test "apply: no fixes returns source unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try apply(a, "hello world", &.{});
    try std.testing.expectEqualStrings("hello world", result.fixed);
    try std.testing.expectEqual(@as(u32, 0), result.applied_count);
}

test "apply: single fix replaces range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const fix = Diagnostic.Fix{
        .range = .{
            .start = .{ .offset = 6, .line = 1, .column = 7 },
            .end = .{ .offset = 11, .line = 1, .column = 12 },
        },
        .text = "everyone",
    };
    const entry = Diagnostic.Entry{ .fix = &fix };

    const result = try apply(a, "hello world", &.{entry});
    try std.testing.expectEqualStrings("hello everyone", result.fixed);
    try std.testing.expectEqual(@as(u32, 1), result.applied_count);
}

test "apply: multiple non-overlapping fixes applied in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f1 = Diagnostic.Fix{
        .range = .{ .start = .{ .offset = 0 }, .end = .{ .offset = 3 } },
        .text = "HI",
    };
    const f2 = Diagnostic.Fix{
        .range = .{ .start = .{ .offset = 6 }, .end = .{ .offset = 11 } },
        .text = "wgpu",
    };
    const entries = [_]Diagnostic.Entry{
        .{ .fix = &f2 }, // intentionally out of order to test sort
        .{ .fix = &f1 },
    };

    const result = try apply(a, "abc.xyhello", &entries);
    try std.testing.expectEqualStrings("HI.xywgpu", result.fixed);
    try std.testing.expectEqual(@as(u32, 2), result.applied_count);
}

test "apply: overlapping fix is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f1 = Diagnostic.Fix{
        .range = .{ .start = .{ .offset = 0 }, .end = .{ .offset = 5 } },
        .text = "XXXXX",
    };
    const f2 = Diagnostic.Fix{
        // Starts at 3 — inside f1's range — so it conflicts.
        .range = .{ .start = .{ .offset = 3 }, .end = .{ .offset = 7 } },
        .text = "YYYY",
    };
    const entries = [_]Diagnostic.Entry{
        .{ .fix = &f1 },
        .{ .fix = &f2 },
    };

    const result = try apply(a, "abcdefghij", &entries);
    // f1 applied, f2 dropped as overlap.
    try std.testing.expectEqualStrings("XXXXXfghij", result.fixed);
    try std.testing.expectEqual(@as(u32, 1), result.applied_count);
    try std.testing.expectEqual(@as(u32, 1), result.conflicted_count);
}

test "apply: out-of-range fix is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = Diagnostic.Fix{
        .range = .{ .start = .{ .offset = 0 }, .end = .{ .offset = 100 } },
        .text = "x",
    };
    const result = try apply(a, "abc", &.{.{ .fix = &f }});
    try std.testing.expectEqualStrings("abc", result.fixed);
    try std.testing.expectEqual(@as(u32, 1), result.conflicted_count);
}

test "apply: empty source with no fixes returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try apply(a, "", &.{});
    try std.testing.expectEqualStrings("", result.fixed);
}
