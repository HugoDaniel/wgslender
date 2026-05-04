//! Side-table mirror of `Symbol.flags.is_live`.
//!
//! B.M3 of the Symbol-immutability arc (audit plan §11). The end goal is
//! to delete `Symbol.flags.is_live` and have `Dce.mark` (and the
//! tree-shaking-off branches that set every symbol live) populate this
//! side-table instead of mutating the symbol record. This module is the
//! first half of that change: `Dce.mark` writes *both* — the existing
//! field stays the source of truth for current readers, the side-table
//! is the forward-looking source.
//!
//! Bit-packed (`DynamicBitSetUnmanaged`) so a 64K-symbol module costs
//! 8KB regardless of liveness density. Lifetime is tied to the arena
//! passed at `init`; callers allocate a fresh `Liveness` per pipeline
//! run and discard it when the arena is freed.
//!
//! Bounds checks match the existing field-side `idx < symbols.len`
//! guards inside `Dce.mark` so a mirrored call is a strict no-op
//! whenever the field-side write is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const Liveness = @This();

bits: std.DynamicBitSetUnmanaged,

pub fn init(arena: Allocator, n_symbols: usize) !Liveness {
    return .{ .bits = try std.DynamicBitSetUnmanaged.initEmpty(arena, n_symbols) };
}

/// Mirror of the field-side `symbols[idx].flags.is_live = true`. Silent
/// on out-of-range indices — same shape as the field-side
/// `if (idx < module.symbols.items.len)` guard at Dce.zig:62-65.
pub fn markLive(self: *Liveness, sym_idx: u32) void {
    if (sym_idx >= self.bits.bit_length) return;
    self.bits.set(sym_idx);
}

/// Marks every in-range symbol live. Used by the "no entry points →
/// keep everything" branch at Dce.zig:38-43, and by the
/// `tree_shaking=false` branches in Minifier/Compiler/MinifyEstimator.
pub fn markAllLive(self: *Liveness) void {
    self.bits.setRangeValue(.{ .start = 0, .end = self.bits.bit_length }, true);
}

pub fn isLive(self: Liveness, sym_idx: u32) bool {
    if (sym_idx >= self.bits.bit_length) return false;
    return self.bits.isSet(sym_idx);
}

/// Number of live symbols (popcount). Cheap; iterates 64-bit words.
pub fn countLive(self: Liveness) u32 {
    return @intCast(self.bits.count());
}

/// Number of dead symbols within the bit-set length. Symbols added to
/// the module *after* `init` are not counted.
pub fn countDead(self: Liveness) u32 {
    return @intCast(self.bits.bit_length - self.bits.count());
}

/// Mirror writes back to `Symbol.flags.is_live`. Used by callers that
/// produce a `Liveness` separately (e.g. testing) and want the
/// field-side state to match for backward-compat readers. The
/// production writers in `Dce.mark` and the tree-shaking-off branches
/// already write both fields directly, so this is mostly a test hook.
pub fn mirrorToFlags(self: Liveness, module: *Ast.Module) void {
    const n = @min(self.bits.bit_length, module.symbols.items.len);
    for (module.symbols.items[0..n], 0..) |*sym, i| {
        sym.flags.is_live = self.bits.isSet(i);
    }
}

/// Debug-only invariant: every symbol's `flags.is_live` equals its
/// mirrored bit. Out-of-range symbols (added after `init`) are compared
/// against `false`. Intended for tests/parity checks at the end of a
/// pipeline that drove both paths in lockstep.
pub fn assertParity(self: Liveness, module: *const Ast.Module) void {
    if (!std.debug.runtime_safety) return;
    for (module.symbols.items, 0..) |sym, i| {
        const side = if (i < self.bits.bit_length) self.bits.isSet(i) else false;
        std.debug.assert(sym.flags.is_live == side);
    }
}

// =========================================================================
// Tests
// =========================================================================

test "init: zero-fills the bit-set" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const liv = try Liveness.init(arena, 8);
    for (0..8) |i| try std.testing.expect(!liv.isLive(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0), liv.countLive());
    try std.testing.expectEqual(@as(u32, 8), liv.countDead());
}

test "markLive / isLive round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var liv = try Liveness.init(arena, 4);
    liv.markLive(1);
    liv.markLive(3);
    try std.testing.expect(!liv.isLive(0));
    try std.testing.expect(liv.isLive(1));
    try std.testing.expect(!liv.isLive(2));
    try std.testing.expect(liv.isLive(3));
    try std.testing.expectEqual(@as(u32, 2), liv.countLive());
    try std.testing.expectEqual(@as(u32, 2), liv.countDead());
}

test "markLive: duplicate set is a no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var liv = try Liveness.init(arena, 2);
    liv.markLive(0);
    liv.markLive(0);
    try std.testing.expect(liv.isLive(0));
    try std.testing.expectEqual(@as(u32, 1), liv.countLive());
}

test "markLive / isLive: out-of-range index is a silent no-op / false" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var liv = try Liveness.init(arena, 4);
    liv.markLive(99);
    try std.testing.expect(!liv.isLive(99));
    try std.testing.expectEqual(@as(u32, 0), liv.countLive());
}

test "markAllLive: every in-range symbol becomes live" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var liv = try Liveness.init(arena, 5);
    liv.markAllLive();
    for (0..5) |i| try std.testing.expect(liv.isLive(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 5), liv.countLive());
    try std.testing.expectEqual(@as(u32, 0), liv.countDead());
}

test "init: zero-length bit-set is well-defined" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var liv = try Liveness.init(arena, 0);
    try std.testing.expectEqual(@as(u32, 0), liv.countLive());
    try std.testing.expectEqual(@as(u32, 0), liv.countDead());
    liv.markAllLive();
    try std.testing.expectEqual(@as(u32, 0), liv.countLive());
}

test "mirrorToFlags: writes back to Symbol.flags.is_live" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, .{ .original_name = "a", .kind = .let, .flags = .{} });
    try module.symbols.append(arena, .{ .original_name = "b", .kind = .let, .flags = .{} });
    try module.symbols.append(arena, .{ .original_name = "c", .kind = .let, .flags = .{} });

    var liv = try Liveness.init(arena, 3);
    liv.markLive(0);
    liv.markLive(2);
    liv.mirrorToFlags(&module);

    try std.testing.expect(module.symbols.items[0].flags.is_live);
    try std.testing.expect(!module.symbols.items[1].flags.is_live);
    try std.testing.expect(module.symbols.items[2].flags.is_live);
}

test "assertParity: matches when liveness mirrors flags" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, .{ .original_name = "a", .kind = .let, .flags = .{ .is_live = true } });
    try module.symbols.append(arena, .{ .original_name = "b", .kind = .let, .flags = .{ .is_live = false } });

    var liv = try Liveness.init(arena, 2);
    liv.markLive(0);
    liv.assertParity(&module);
}

fn newTestModule(arena: Allocator) !Ast.Module {
    const root = try arena.create(Ast.Scope);
    root.* = Ast.Scope.init(null, .module);
    return Ast.Module.init(root, "");
}
