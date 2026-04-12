const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !struct { handler: *Handler, source: [:0]const u8 } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler, .source = source };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

test "references: variable with multiple usages" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { let a = x; let b = x; return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on declaration of 'x'
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult; // 'x' in "const x"
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 3 usages = 4
    try std.testing.expectEqual(@as(usize, 4), refs.?.len);
}

test "references: exclude declaration" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const refs_with = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs_with != null);
    defer std.testing.allocator.free(refs_with.?);
    const refs_without = try ctx.handler.computeReferences("test://file.wgsl", pos, false);
    try std.testing.expect(refs_without != null);
    defer std.testing.allocator.free(refs_without.?);
    try std.testing.expect(refs_with.?.len == refs_without.?.len + 1);
}

test "references: struct type used in annotations" {
    const source: [:0]const u8 = "struct S { x: f32 } fn a(s: S) {} fn b(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position on struct name
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult; // 'S' in "struct S"
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 2 type refs = 3
    try std.testing.expectEqual(@as(usize, 3), refs.?.len);
}

test "references: unused symbol returns only declaration" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    try std.testing.expectEqual(@as(usize, 1), refs.?.len);
}

test "references: whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeReferences("test://file.wgsl", .{ .line = 0, .character = 2 }, true);
    try std.testing.expect(result == null);
}

// =========================================================================
// Edge cases
// =========================================================================

test "references: function used as callee in nested expressions" {
    const source: [:0]const u8 =
        \\fn helper(x: f32) -> f32 { return x * 2.0; }
        \\fn main() {
        \\  let a = helper(1.0);
        \\  let b = helper(helper(2.0));
        \\  let c = helper(a) + helper(b);
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult; // 'h' in helper decl
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, false);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // helper is called 5 times (lines 2, 3x2, 4x2)
    try std.testing.expect(refs.?.len >= 4);
}

test "references: struct used in multiple type positions" {
    const source: [:0]const u8 =
        \\struct Vec2 { x: f32, y: f32 }
        \\fn make() -> Vec2 { return Vec2(0.0, 0.0); }
        \\fn use(v: Vec2) -> f32 { return v.x; }
        \\const ZERO: Vec2 = Vec2(0.0, 0.0);
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult; // 'V' in struct Vec2
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + return type + constructor calls + param type + const type
    try std.testing.expect(refs.?.len >= 4);
}

test "references: parameter referenced in function body" {
    const source: [:0]const u8 = "fn f(val: f32) -> f32 { let a = val; let b = val + val; return b; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Find 'val' parameter
    const val_pos = std.mem.indexOf(u8, source, "val") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(val_pos)) orelse return error.TestUnexpectedResult;
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 3 usages
    try std.testing.expectEqual(@as(usize, 4), refs.?.len);
}

test "references: position past end of file returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeReferences("test://file.wgsl", .{ .line = 99, .character = 0 }, true);
    try std.testing.expect(result == null);
}

test "references: empty source returns null" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeReferences("test://file.wgsl", .{ .line = 0, .character = 0 }, true);
    try std.testing.expect(result == null);
}

test "references: variable in for loop body" {
    const source: [:0]const u8 = "const N: u32 = 10; fn f() { for (var i: u32 = 0; i < N; i++) { let x = N; } }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult; // 'N' in const
    const refs = try ctx.handler.computeReferences("test://file.wgsl", pos, true);
    try std.testing.expect(refs != null);
    defer std.testing.allocator.free(refs.?);
    // Declaration + 2 usages in for loop
    try std.testing.expect(refs.?.len >= 3);
}
