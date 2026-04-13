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

fn freeLenses(lenses: []const Handler.CodeLensInfo) void {
    for (lenses) |l| std.testing.allocator.free(l.title);
    std.testing.allocator.free(lenses);
}

test "code lens: function with references" {
    const source: [:0]const u8 = "fn helper() {} fn a() { helper(); } fn b() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // Should have lenses for helper, a, b
    try std.testing.expect(lenses.len >= 1);
    // Find the helper lens — it should have 2 references
    for (lenses) |l| {
        if (l.range.start.character == 3) { // "helper" starts at col 3
            try std.testing.expect(std.mem.indexOf(u8, l.title, "2") != null);
        }
    }
}

test "code lens: unused function shows 0" {
    const source: [:0]const u8 = "fn unused_fn() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expectEqual(@as(usize, 1), lenses.len);
    try std.testing.expect(std.mem.indexOf(u8, lenses[0].title, "0") != null);
}

test "code lens: struct with type refs" {
    const source: [:0]const u8 = "struct S { x: f32 } fn a(s: S) {} fn b(s: S) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // Should have lens for struct S with 2 references
    try std.testing.expect(lenses.len >= 1);
}

test "code lens: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expectEqual(@as(usize, 0), lenses.len);
}

test "code lens: multiple functions and structs" {
    const source: [:0]const u8 = "struct A { x: f32 } struct B { a: A } fn use_a(a: A) {} fn use_b(b: B) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // 2 structs + 2 functions = 4 lenses
    try std.testing.expectEqual(@as(usize, 4), lenses.len);
}

test "code lens: pluralization" {
    const source: [:0]const u8 = "fn helper() {} fn main() { helper(); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // helper has 1 reference, should say "1 reference" (not "references")
    for (lenses) |l| {
        if (std.mem.indexOf(u8, l.title, "1 reference") != null) {
            try std.testing.expect(std.mem.indexOf(u8, l.title, "1 references") == null);
        }
    }
}

test "code lens: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const lenses = try handler.computeCodeLens("test://nonexistent.wgsl");
    try std.testing.expectEqual(@as(usize, 0), lenses.len);
}

fn hasLensContaining(lenses: []const Handler.CodeLensInfo, needle: []const u8) bool {
    for (lenses) |l| {
        if (std.mem.indexOf(u8, l.title, needle) != null) return true;
    }
    return false;
}

test "code lens: entry point with bindings shows binding summary" {
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> uniforms: vec4f;
        \\@group(0) @binding(1) var tex_sampler: sampler;
        \\@fragment fn main() -> @location(0) vec4f { return vec4f(0.0); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    // Should have a binding summary lens
    try std.testing.expect(hasLensContaining(lenses, "@group(0) @binding(0)"));
    try std.testing.expect(hasLensContaining(lenses, "@group(0) @binding(1)"));
}

test "code lens: compute shader shows workgroup size" {
    const source: [:0]const u8 =
        \\@compute @workgroup_size(8, 8, 1) fn main() {}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expect(hasLensContaining(lenses, "workgroup: 8x8x1"));
}

test "code lens: no bindings means no binding lens" {
    const source: [:0]const u8 =
        \\@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const lenses = try ctx.handler.computeCodeLens("test://file.wgsl");
    defer freeLenses(lenses);
    try std.testing.expect(!hasLensContaining(lenses, "@group"));
    try std.testing.expect(!hasLensContaining(lenses, "workgroup"));
}
