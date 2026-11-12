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

test "call hierarchy: prepare on function" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult; // 'h' in helper
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", pos);
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("helper", item.?.name);
}

test "call hierarchy: prepare on non-function returns null" {
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", pos);
    try std.testing.expect(item == null);
}

test "call hierarchy: incoming calls" {
    const source: [:0]const u8 = "fn callee() {} fn caller_a() { callee(); } fn caller_b() { callee(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeIncomingCalls("test://file.wgsl", "callee");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 2), calls.len);
}

test "call hierarchy: outgoing calls" {
    const source: [:0]const u8 = "fn a() {} fn b() {} fn caller() { a(); b(); a(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "caller");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    // Should have calls to 'a' and 'b'
    try std.testing.expectEqual(@as(usize, 2), calls.len);
}

test "call hierarchy: function with no calls" {
    const source: [:0]const u8 = "fn isolated() { let x = 1; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "isolated");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "call hierarchy: chain of calls a->b->c" {
    const source: [:0]const u8 = "fn c() {} fn b() { c(); } fn a() { b(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    // a's outgoing calls should include b
    const out_a = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "a");
    defer {
        for (out_a) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(out_a);
    }
    try std.testing.expectEqual(@as(usize, 1), out_a.len);

    // b's incoming should include a
    const in_b = try ctx.handler.computeIncomingCalls("test://file.wgsl", "b");
    defer {
        for (in_b) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(in_b);
    }
    try std.testing.expectEqual(@as(usize, 1), in_b.len);
}

test "call hierarchy: multiple calls to same function" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); helper(); helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const out = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "main");
    defer {
        for (out) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(out);
    }
    // Should have 1 entry for helper, with 3 call locations
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 3), out[0].from_ranges.len);
}

test "call hierarchy: prepare on whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const item = try ctx.handler.prepareCallHierarchy("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(item == null);
}

test "call hierarchy: nonexistent function returns empty" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeOutgoingCalls("test://file.wgsl", "nonexistent");
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "call hierarchy: incoming calls from nested expressions" {
    const source: [:0]const u8 = "fn callee() -> f32 { return 1.0; } fn caller() { let x = callee() + callee(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const calls = try ctx.handler.computeIncomingCalls("test://file.wgsl", "callee");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqual(@as(usize, 2), calls[0].from_ranges.len);
}

// =========================================================================
// Retired tombstones
// =========================================================================

test "call hierarchy: retired functions do not appear in name-scan results" {
    const uri = "test://file.wgsl";
    const source: [:0]const u8 =
        "fn dup() {} fn dup() -> i32 { return 1; } fn caller() -> i32 { return dup(); }";
    const ctx = try setup(source);
    defer teardown(ctx);

    const doc = ctx.handler.documents.getPtr(uri).?;
    const module = doc.parse.?.module;

    // No splice path detaches a module-level function today, so synthesize
    // the tombstone on a real duplicate-function module: the first `dup`
    // symbol is marked retired exactly as a splice would mark a detached
    // declaration, while the scope map still names the second, active copy.
    var dup_syms: [2]usize = undefined;
    var n: usize = 0;
    for (module.symbols.items, 0..) |sym, i| {
        if (sym.kind == .function and std.mem.eql(u8, sym.original_name, "dup")) {
            if (n < dup_syms.len) dup_syms[n] = i;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    const retired_idx = dup_syms[0];
    const active_idx = dup_syms[1];
    try std.testing.expect(!module.symbols.items[retired_idx].flags.is_retired);
    module.symbols.items[retired_idx].flags.is_retired = true;

    const calls = try ctx.handler.computeOutgoingCalls(uri, "caller");
    defer {
        for (calls) |c| std.testing.allocator.free(c.from_ranges);
        std.testing.allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);

    // The range must point at the active declaration, never the tombstone.
    const active_loc = module.symbols.items[active_idx].loc;
    const active_pos = Handler.offsetToLspPosition(source, active_loc) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(active_pos.line, calls[0].to.range.start.line);
    try std.testing.expectEqual(active_pos.character, calls[0].to.range.start.character);
}
