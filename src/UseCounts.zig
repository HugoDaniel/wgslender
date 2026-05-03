//! Side-table mirror of `Symbol.use_count`.
//!
//! B.M1 of the Symbol-immutability arc (audit plan §11). The end goal is
//! to delete `Symbol.use_count` and have AstVisit Pass 2 produce a
//! side-table instead of mutating the symbol record. This module is the
//! first half of that change: AstVisit gains an *optional* mirror, so
//! callers can drive the walker with a side-table attached and verify it
//! tracks the existing field exactly. Production paths leave the
//! side-table null today, so observable behavior is unchanged.
//!
//! Mirrors AstVisit's increment/decrement protocol exactly:
//!   - `.add` mode at AstVisit.zig:273 (ident) / :355 (type.ident) →
//!     `increment(ref)`
//!   - `.sub` mode at AstVisit.zig:300 (ident, gated by
//!     `flags.use_count_incremented`) / :365 (type.ident, gated by
//!     `ref.isValid()`) → `decrement(ref)`
//!
//! Bounds and validity checks match the existing field-side guards so a
//! mirrored call is a strict no-op whenever the field-side write is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const UseCounts = @This();

/// Dense per-symbol counts, indexed by `SymbolIndex.index()`. Length
/// equals the symbol-table size at `init`-time. Subsequent symbol
/// appends are caller-coordinated; this side-table does not auto-grow.
counts: []u32,

/// Bumped by `reset()`. Reserved for the B.M5 "decrement crosses a
/// reset boundary" check once readers migrate off the field.
epoch: u64 = 0,

pub fn init(arena: Allocator, n_symbols: usize) !UseCounts {
    const counts = try arena.alloc(u32, n_symbols);
    @memset(counts, 0);
    return .{ .counts = counts };
}

/// Mirror of the field-side `symbols[idx].use_count += 1`. Silent on
/// `.none` and out-of-range indices — same shape as the field-side
/// `if (idx < ctx.symbols.len)` guard.
pub fn increment(self: *UseCounts, sym: Ast.SymbolIndex) void {
    if (!sym.isValid()) return;
    const idx = sym.index();
    if (idx >= self.counts.len) return;
    self.counts[idx] += 1;
}

/// Mirror of the field-side saturating decrement at AstVisit.zig:299.
/// Caller is responsible for matching the field-side gate
/// (`flags.use_count_incremented` for idents, `ref.isValid()` for
/// type-idents) before calling this — the side-table itself only
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

/// Zero every count and bump `epoch`. The epoch bump is the hook that
/// B.M5+ will use to assert decrements pair with same-epoch increments.
pub fn reset(self: *UseCounts) void {
    @memset(self.counts, 0);
    self.epoch +%= 1;
}

/// Debug-only invariant: every symbol's `use_count` equals its mirrored
/// side-table count. Intended for the end of a test scenario that drove
/// both paths in lockstep — `assertParity` is what flushes the "I think
/// I'm in sync" assumption into a hard check. Out-of-range symbols
/// (added after `init`) are compared against zero.
pub fn assertParity(self: UseCounts, module: *const Ast.Module) void {
    if (!std.debug.runtime_safety) return;
    for (module.symbols.items, 0..) |sym, i| {
        const side = if (i < self.counts.len) self.counts[i] else 0;
        std.debug.assert(sym.use_count == side);
    }
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
