//! Per-symbol use counts produced by AstVisit Pass 2.
//!
//! Replaces the `Symbol.use_count` field deleted in B.M5 of the Symbol-
//! immutability arc. Owned by `Module.use_counts`; sized to
//! `module.symbols.items.len` at parse time. The incremental hot path
//! (`Splice.zig`) calls `Module.resizeUseCounts` to grow the table when a
//! splice introduces new symbols.
//!
//! AstVisit's increment/decrement protocol:
//!   - `.add` mode at AstVisit.zig (ident, type.ident) → `increment(ref)`
//!   - `.sub` mode (ident, gated by `IdentExpr.was_counted`; type.ident,
//!     gated by `ref.isValid()`) → `decrement(ref)`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const UseCounts = @This();

/// Dense per-symbol counts, indexed by `SymbolIndex.index()`. Length
/// equals the symbol-table size at `init`-time. Grown by
/// `Module.resizeUseCounts` when an incremental splice appends new
/// symbols.
counts: []u32,

/// Bumped by `reset()`. Reserved for the "decrement crosses a reset
/// boundary" debug check once the visitor incremental story
/// stabilizes.
epoch: u64 = 0,

pub fn init(arena: Allocator, n_symbols: usize) !UseCounts {
    const counts = try arena.alloc(u32, n_symbols);
    @memset(counts, 0);
    return .{ .counts = counts };
}

/// Bump the count for `sym` by 1. Silent no-op on `.none` and out-of-
/// range indices — the latter so the AstVisit add-walk can run before
/// `Module.resizeUseCounts` has caught up to a freshly appended symbol
/// without crashing.
pub fn increment(self: *UseCounts, sym: Ast.SymbolIndex) void {
    if (!sym.isValid()) return;
    const idx = sym.index();
    if (idx >= self.counts.len) return;
    self.counts[idx] += 1;
}

/// Saturating decrement of the count for `sym`. Caller is responsible
/// for matching the per-ident gate (`IdentExpr.was_counted` for idents,
/// `ref.isValid()` for type-idents) before calling — this method only
/// guards against indexing OOB and underflow.
pub fn decrement(self: *UseCounts, sym: Ast.SymbolIndex) void {
    if (!sym.isValid()) return;
    const idx = sym.index();
    if (idx >= self.counts.len) return;
    if (self.counts[idx] > 0) self.counts[idx] -= 1;
}

pub fn get(self: UseCounts, sym: Ast.SymbolIndex) u32 {
    if (!sym.isValid()) return 0;
    const idx = sym.index();
    if (idx >= self.counts.len) return 0;
    return self.counts[idx];
}

/// Zero every count and bump `epoch`. Reserved for future incremental
/// scenarios that need to detect decrements crossing a reset boundary.
pub fn reset(self: *UseCounts) void {
    @memset(self.counts, 0);
    self.epoch +%= 1;
}

test "init: zero-fills the slice" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const uc = try UseCounts.init(arena, 5);
    for (uc.counts) |c| try std.testing.expectEqual(@as(u32, 0), c);
}

test "increment / decrement / get round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var uc = try UseCounts.init(arena, 4);
    const s2: Ast.SymbolIndex = @enumFromInt(2);

    uc.increment(s2);
    uc.increment(s2);
    uc.increment(s2);
    try std.testing.expectEqual(@as(u32, 3), uc.get(s2));

    uc.decrement(s2);
    try std.testing.expectEqual(@as(u32, 2), uc.get(s2));
}

test "increment / decrement / get: .none is a silent no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var uc = try UseCounts.init(arena, 2);
    uc.increment(.none);
    uc.decrement(.none);
    try std.testing.expectEqual(@as(u32, 0), uc.get(.none));
    for (uc.counts) |c| try std.testing.expectEqual(@as(u32, 0), c);
}

test "increment / decrement / get: out-of-range index is a silent no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var uc = try UseCounts.init(arena, 2);
    const s10: Ast.SymbolIndex = @enumFromInt(10);
    uc.increment(s10);
    uc.decrement(s10);
    try std.testing.expectEqual(@as(u32, 0), uc.get(s10));
    for (uc.counts) |c| try std.testing.expectEqual(@as(u32, 0), c);
}

test "decrement: saturating at zero" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var uc = try UseCounts.init(arena, 2);
    const s0: Ast.SymbolIndex = @enumFromInt(0);
    uc.decrement(s0);
    uc.decrement(s0);
    try std.testing.expectEqual(@as(u32, 0), uc.get(s0));
}

test "reset: zeros counts and bumps epoch" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var uc = try UseCounts.init(arena, 3);
    const s1: Ast.SymbolIndex = @enumFromInt(1);
    uc.increment(s1);
    uc.increment(s1);
    try std.testing.expectEqual(@as(u32, 2), uc.get(s1));
    const epoch_before = uc.epoch;

    uc.reset();
    try std.testing.expectEqual(@as(u32, 0), uc.get(s1));
    try std.testing.expectEqual(epoch_before +% 1, uc.epoch);
}
