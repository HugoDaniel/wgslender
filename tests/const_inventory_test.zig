//! Const-inventory tests (pacer plans/08 knob-lift, Phase 0 API spike).
//!
//! `Reflect.constInventory` surfaces every module-scope `const` declaration
//! with the four things the studio's knob-lift transform needs — name,
//! scalar type, initializer text, and full declaration span — plus a
//! `liftable` flag that is `false` when the const is referenced from a
//! const-required position (array element count, `@workgroup_size`,
//! `const_assert`, an attribute argument, or — transitively — another
//! const/override whose value is itself const-required). A liftable const
//! can be replaced by a runtime uniform value without invalidating the
//! module; a non-liftable one cannot, and the transform must refuse it.

const std = @import("std");
const wgslender = @import("wgslender");
const Reflect = wgslender.Reflect;

/// Bind-parse a snippet to a module (pass-2 complete). Mirrors the parse
/// path in `root.zig`'s `reflect`. Every fixture below is valid WGSL, so a
/// parse error means the fixture is wrong, not that the inventory is empty —
/// `parseOk` says so instead of handing back a partial AST.
const parse = @import("parse_ok.zig").parseOk;

fn findConst(inv: []const Reflect.ConstInfo, name: []const u8) ?Reflect.ConstInfo {
    for (inv) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

test "constInventory: names, values, spans, liftable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const source: [:0]const u8 =
        \\const TUN_SPEED: f32 = 0.55;
        \\const GRID_N: u32 = 4u;
        \\var<private> cells: array<f32, GRID_N>;
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    return vec4f(TUN_SPEED * cells[0]);
        \\}
    ;

    const module = try parse(aa, source);
    const inv = try Reflect.constInventory(aa, module);
    try std.testing.expectEqual(@as(usize, 2), inv.len);

    // TUN_SPEED: a scalar f32 used only in a runtime expression → liftable.
    const speed = findConst(inv, "TUN_SPEED") orelse return error.MissingConst;
    try std.testing.expectEqualStrings("f32", speed.typ);
    try std.testing.expectEqualStrings("0.55", speed.value);
    try std.testing.expect(speed.liftable);
    try std.testing.expect(speed.decl_span.present());
    try std.testing.expectEqualStrings(
        "const TUN_SPEED: f32 = 0.55;",
        source[speed.decl_span.start..speed.decl_span.end],
    );

    // GRID_N: used as an array element count → const-required, NOT liftable.
    const grid = findConst(inv, "GRID_N") orelse return error.MissingConst;
    try std.testing.expectEqualStrings("u32", grid.typ);
    try std.testing.expectEqualStrings("4u", grid.value);
    try std.testing.expect(!grid.liftable);
}

test "constInventory: @workgroup_size and const_assert pin non-liftable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const source: [:0]const u8 =
        \\const WG_X: u32 = 8u;
        \\const LIMIT: i32 = 3;
        \\const AMP: f32 = 1.5;
        \\const_assert(LIMIT > 0);
        \\@compute @workgroup_size(WG_X, 1, 1)
        \\fn main() {
        \\    let x = AMP * f32(LIMIT);
        \\}
    ;

    const module = try parse(aa, source);
    const inv = try Reflect.constInventory(aa, module);
    try std.testing.expectEqual(@as(usize, 3), inv.len);

    // WG_X drives a workgroup dimension; LIMIT sits in a const_assert.
    try std.testing.expect(!(findConst(inv, "WG_X") orelse return error.MissingConst).liftable);
    try std.testing.expect(!(findConst(inv, "LIMIT") orelse return error.MissingConst).liftable);
    // AMP only feeds a runtime `let` → liftable.
    try std.testing.expect((findConst(inv, "AMP") orelse return error.MissingConst).liftable);
}

test "constInventory: const-required-ness propagates through const chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // BASE feeds N (another const), and N is an array size. Lifting BASE
    // would make N non-const and invalidate the array → BASE is NOT liftable.
    // FREE is a lone f32 used only at runtime → liftable.
    const source: [:0]const u8 =
        \\const BASE: u32 = 2u;
        \\const N: u32 = BASE * 2u;
        \\const FREE: f32 = 0.25;
        \\var<private> buf: array<f32, N>;
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    return vec4f(FREE * buf[0]);
        \\}
    ;

    const module = try parse(aa, source);
    const inv = try Reflect.constInventory(aa, module);

    try std.testing.expect(!(findConst(inv, "N") orelse return error.MissingConst).liftable);
    try std.testing.expect(!(findConst(inv, "BASE") orelse return error.MissingConst).liftable);
    try std.testing.expect((findConst(inv, "FREE") orelse return error.MissingConst).liftable);
}
