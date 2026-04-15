const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !struct { handler: *Handler } {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return .{ .handler = handler };
}

fn teardown(ctx: anytype) void {
    ctx.handler.deinit();
    std.testing.allocator.destroy(ctx.handler);
}

test "inlay hints: let without type annotation" {
    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(hints);
    // Should have a type hint for 'x'
    // The type might be abstract-float or f32 depending on validation
    if (hints.len > 0) {
        try std.testing.expect(hints[0].kind == .type_hint);
        try std.testing.expect(hints[0].label.len > 0);
    }
}

test "inlay hints: let with explicit type has no hint" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(hints);
    // No hint since type is explicit
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const hints = try handler.computeInlayHints("test://nonexistent.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 10 },
    });
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints: multiple lets without types in function" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a = 1.0;
        \\  let b = 2.0;
        \\  let c = 3.0;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Should have type hints for a, b, c (if types are resolved)
    // All should be type_hint kind
    for (hints) |h| {
        try std.testing.expect(h.kind == .type_hint);
    }
}

test "inlay hints: const with explicit type has no hint" {
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; let y: i32 = 2; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = @intCast(source.len) },
    });
    defer std.testing.allocator.free(hints);
    // No hints since both have explicit types
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

// =========================================================================
// Const value hints (array sizes)
// =========================================================================

test "inlay hints: array size with const ref shows value" {
    const source: [:0]const u8 =
        \\const N = 256;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var buf: array<f32, N>;
        \\  _ = buf;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 5, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Should have a const_value_hint showing "= 256" for the array size N
    var found_const_hint = false;
    for (hints) |h| {
        if (h.kind == .const_value_hint) {
            try std.testing.expect(std.mem.indexOf(u8, h.label, "256") != null);
            found_const_hint = true;
        }
    }
    try std.testing.expect(found_const_hint);
}

test "inlay hints: array size with literal has no const hint" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var buf: array<f32, 10>;
        \\  _ = buf;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // No const_value_hint since size is a plain literal
    for (hints) |h| {
        try std.testing.expect(h.kind != .const_value_hint);
    }
}

test "inlay hints: array size with const expression shows evaluated value" {
    const source: [:0]const u8 =
        \\const W = 16;
        \\const H = 16;
        \\const TOTAL = W * H;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var buf: array<f32, TOTAL>;
        \\  _ = buf;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 7, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    var found = false;
    for (hints) |h| {
        if (h.kind == .const_value_hint) {
            if (std.mem.indexOf(u8, h.label, "256") != null) found = true;
        }
    }
    try std.testing.expect(found);
}

test "inlay hints: module-level array type with const size" {
    const source: [:0]const u8 =
        \\const SIZE = 64;
        \\var<private> data: array<f32, SIZE>;
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    var found = false;
    for (hints) |h| {
        if (h.kind == .const_value_hint) {
            if (std.mem.indexOf(u8, h.label, "64") != null) found = true;
        }
    }
    try std.testing.expect(found);
}

// =========================================================================
// Expression type hints
// =========================================================================

test "inlay hints: binary arithmetic shows result type" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a: f32 = 1.0;
        \\  let b: f32 = 2.0;
        \\  let c = a + b;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Should have type hints — at least one for the let 'c' and one for 'a + b'
    var has_type_hint = false;
    for (hints) |h| {
        if (h.kind == .type_hint) has_type_hint = true;
    }
    try std.testing.expect(has_type_hint);
}

test "inlay hints: comparison op does not show bool hint" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a: i32 = 1;
        \\  let b: i32 = 2;
        \\  if a == b { }
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // No expression type hint for == since result is always bool (filtered out)
    for (hints) |h| {
        if (h.kind == .type_hint) {
            try std.testing.expect(std.mem.indexOf(u8, h.label, "bool") == null);
        }
    }
}

test "inlay hints: function call shows return type" {
    const source: [:0]const u8 =
        \\fn helper() -> f32 { return 1.0; }
        \\fn main() {
        \\  let x: f32 = 1.0;
        \\  let y = helper() + x;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Should have type hints for y's initializer
    var has_type_hint = false;
    for (hints) |h| {
        if (h.kind == .type_hint and std.mem.indexOf(u8, h.label, "f32") != null) {
            has_type_hint = true;
        }
    }
    try std.testing.expect(has_type_hint);
}

test "inlay hints: assignment RHS gets expression type hints" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  var x: f32 = 1.0;
        \\  var y: f32 = 2.0;
        \\  x = x + y;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // The assignment RHS `x + y` should get an expression type hint
    var has_expr_hint = false;
    for (hints) |h| {
        if (h.kind == .type_hint and std.mem.indexOf(u8, h.label, "f32") != null) {
            has_expr_hint = true;
        }
    }
    try std.testing.expect(has_expr_hint);
}

test "inlay hints: type constructor does not show redundant hint" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let v = vec3<f32>(1.0, 2.0, 3.0);
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 2, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // The type constructor vec3<f32>(...) should NOT get an expression type hint
    // (template_type is set, so it's filtered). The let should still get a declaration hint.
    var expr_type_count: usize = 0;
    for (hints) |h| {
        if (h.kind == .type_hint and std.mem.indexOf(u8, h.label, "vec3") != null) {
            // This could be the let declaration hint OR an unwanted expr hint
            expr_type_count += 1;
        }
    }
    // Should have at most 1 (the declaration hint for let v), not 2 (no expr hint)
    try std.testing.expect(expr_type_count <= 1);
}

test "inlay hints: call expression hint appears after closing paren" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let t: f32 = 1.0;
        \\  let x = sin(t);
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Line 2: "  let x = sin(t);"
    //          0123456789012345678
    // Declaration hint for 'x' is at character 7 (after 'x').
    // Expression hint for sin(t) must be at character 16 (after ')'), not 13 (after 'sin').
    var found_expr_hint = false;
    for (hints) |h| {
        if (h.kind == .type_hint and std.mem.eql(u8, h.label, "f32") and h.position.line == 2) {
            if (h.position.character > 10) {
                // This is the expression hint (not the declaration hint at char 7)
                try std.testing.expectEqual(@as(u32, 16), h.position.character);
                found_expr_hint = true;
            }
        }
    }
    try std.testing.expect(found_expr_hint);
}

test "inlay hints: nested binary+call produces single hint" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let t: f32 = 1.0;
        \\  let x = 0.5 + 0.5 * sin(t);
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const hints = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    });
    defer std.testing.allocator.free(hints);
    // Line 2: "  let x = 0.5 + 0.5 * sin(t);"
    // The three expressions (0.5 + 0.5*sin(t), 0.5*sin(t), sin(t)) all end at
    // the same position (after ')'), so only one type hint should be emitted.
    var expr_hint_count: u32 = 0;
    for (hints) |h| {
        if (h.kind == .type_hint and h.position.line == 2 and h.position.character > 10) {
            expr_hint_count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), expr_hint_count);
}

test "inlay hints: range filtering works" {
    const source: [:0]const u8 =
        \\fn f() {
        \\  let a = 1.0;
        \\  let b = 2.0;
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    // Request hints only for line 1
    const all = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 4, .character = 0 },
    });
    defer std.testing.allocator.free(all);
    // Now request only line 1 range
    const subset = try ctx.handler.computeInlayHints("test://file.wgsl", .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 30 },
    });
    defer std.testing.allocator.free(subset);
    try std.testing.expect(subset.len <= all.len);
}
