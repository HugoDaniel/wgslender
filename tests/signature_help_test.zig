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

test "signature help: builtin function" {
    const source: [:0]const u8 = "fn f() { let x = sin(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position inside sin() — between the parens
    const sin_pos = std.mem.indexOf(u8, source, "sin(") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(sin_pos + 4)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.label);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "sin") != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.active_parameter);
}

test "signature help: user function with parameters" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; } fn f() { let x = add(1.0, 2.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position after first arg "add(1.0, " — active_parameter should be 1
    const call_pos = std.mem.lastIndexOf(u8, source, "2.0") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_pos)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer {
        std.testing.allocator.free(result.?.label);
        std.testing.allocator.free(result.?.parameters);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "add") != null);
    try std.testing.expectEqual(@as(u32, 1), result.?.active_parameter);
    try std.testing.expectEqual(@as(usize, 2), result.?.parameters.len);
}

test "signature help: outside call returns null" {
    const source: [:0]const u8 = "fn f() { let x = 1; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", .{ .line = 0, .character = 18 });
    try std.testing.expect(result == null);
}

test "signature help: unknown document returns null" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const result = try handler.computeSignatureHelp("test://nonexistent.wgsl", .{ .line = 0, .character = 0 });
    try std.testing.expect(result == null);
}

test "signature help: nested calls" {
    const source: [:0]const u8 = "fn f() { let x = sin(cos()); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position inside cos() — should show cos, not sin
    const cos_pos = std.mem.indexOf(u8, source, "cos(") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(cos_pos + 4)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.label);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "cos") != null);
}

// =========================================================================
// Edge cases
// =========================================================================

test "signature help: multi-param builtin clamp" {
    const source: [:0]const u8 = "fn f() { let x = clamp(1.0, 0.0, ); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position after second comma — active parameter should be 2
    const last_comma = std.mem.lastIndexOf(u8, source, ",") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(last_comma + 2)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.label);
    try std.testing.expectEqual(@as(u32, 2), result.?.active_parameter);
}

test "signature help: user function with many params" {
    const source: [:0]const u8 = "fn quad(a: f32, b: f32, c: f32, d: f32) -> f32 { return a; } fn g() { let r = quad(1.0, 2.0, 3.0, 4.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // Position at third argument — active parameter 2
    const third_arg = std.mem.indexOf(u8, source, "3.0") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(third_arg)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer {
        std.testing.allocator.free(result.?.label);
        std.testing.allocator.free(result.?.parameters);
    }
    try std.testing.expectEqual(@as(u32, 2), result.?.active_parameter);
    try std.testing.expectEqual(@as(usize, 4), result.?.parameters.len);
}

test "signature help: empty parens shows first param" {
    const source: [:0]const u8 = "fn f() { let x = abs(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const paren_pos = std.mem.indexOf(u8, source, "abs(") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(paren_pos + 4)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.label);
    try std.testing.expectEqual(@as(u32, 0), result.?.active_parameter);
}

test "signature help: position before any paren returns null" {
    const source: [:0]const u8 = "fn f() { let x = 42; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", .{ .line = 0, .character = 17 });
    try std.testing.expect(result == null);
}

test "signature help: position past end returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", .{ .line = 99, .character = 0 });
    try std.testing.expect(result == null);
}

// =========================================================================
// Real signatures (plan 05, Block 2)
// =========================================================================

test "signature help: builtin label is the spec signature, not an arity range" {
    const source: [:0]const u8 = "fn f() { let x = clamp(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const call_pos = std.mem.indexOf(u8, source, "clamp(") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_pos + 6)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.label);
    // The WGSL spec signature: "fn clamp(e: T, low: T, high: T) -> T"
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "clamp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "->") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "low") != null);
    // ...and specifically not the synthesized arity range.
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "args)") == null);
}

// Struct parameters are `.ident` in the AST, so the hand-rolled switch already
// renders them — the `"?"` fallback only bites texture/sampler/pointer/array.
test "signature help: texture and sampler parameters show their types, not \"?\"" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\fn tap(tex: texture_2d<f32>, smp: sampler, uv: vec2f) -> vec4f {
        \\  return textureSampleLevel(tex, smp, uv, 0.0);
        \\}
        \\@fragment fn f() -> @location(0) vec4f { return tap(t, s, vec2f(0.0)); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const call_pos = std.mem.indexOf(u8, source, "tap(t,") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_pos + 4)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer {
        std.testing.allocator.free(result.?.label);
        std.testing.allocator.free(result.?.parameters);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "texture_2d") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "sampler") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "?") == null);
    try std.testing.expectEqual(@as(usize, 3), result.?.parameters.len);
}

test "signature help: pointer parameter shows its type, not \"?\"" {
    const source: [:0]const u8 =
        \\fn bump(p: ptr<function, f32>) { *p = *p + 1.0; }
        \\fn f() { var v = 0.0; bump(&v); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const call_pos = std.mem.indexOf(u8, source, "bump(&v") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_pos + 5)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeSignatureHelp("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer {
        std.testing.allocator.free(result.?.label);
        std.testing.allocator.free(result.?.parameters);
    }
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?.label, "?") == null);
}
