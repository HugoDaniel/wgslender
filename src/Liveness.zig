//! Per-symbol liveness bits produced by `Dce.mark`.
//!
//! Replaces the `Symbol.flags.is_live` field deleted in B.M5 of the
//! Symbol-immutability arc. Stashed on `Module.liveness` once DCE has
//! run; before that, `bits.bit_length == 0` and `isLive(any)` returns
//! `false`. Production callers (Minifier, Compiler, MinifyEstimator,
//! Linter, LSP Handler) allocate a fresh `Liveness` per pipeline run
//! and either populate it via `Dce.mark` or `markAllLive`.
//!
//! Bit-packed (`DynamicBitSetUnmanaged`) so a 64K-symbol module costs
//! 8KB regardless of liveness density.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const Liveness = @This();

bits: std.DynamicBitSetUnmanaged,

pub fn init(arena: Allocator, n_symbols: usize) !Liveness {
    return .{ .bits = try std.DynamicBitSetUnmanaged.initEmpty(arena, n_symbols) };
}

/// Mark `sym_idx` live. Silent no-op on out-of-range indices.
pub fn markLive(self: *Liveness, sym_idx: u32) void {
    if (sym_idx >= self.bits.bit_length) return;
    self.bits.set(sym_idx);
}

/// Marks every in-range symbol live. Used by the "no entry points →
/// keep everything" branch in `Dce.mark` and by the
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

fn newTestModule(arena: Allocator) !Ast.Module {
    const root = try arena.create(Ast.Scope);
    root.* = Ast.Scope.init(null, .module);
    return Ast.Module.init(root, "");
}
