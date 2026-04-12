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

fn hasSymbol(symbols: []const Handler.DocumentSymbolInfo, name: []const u8) bool {
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

fn freeSymbols(symbols: []const Handler.DocumentSymbolInfo) void {
    for (symbols) |s| {
        if (s.children.len > 0) std.testing.allocator.free(s.children);
    }
    std.testing.allocator.free(symbols);
}

test "document symbols: all declaration types" {
    const source: [:0]const u8 = "struct S { x: f32 }\nconst C: f32 = 1.0;\nfn f() {}\nvar<private> v: f32;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expect(hasSymbol(symbols, "S"));
    try std.testing.expect(hasSymbol(symbols, "C"));
    try std.testing.expect(hasSymbol(symbols, "f"));
    try std.testing.expect(hasSymbol(symbols, "v"));
}

test "document symbols: struct members as children" {
    const source: [:0]const u8 = "struct Point {\n  x: f32,\n  y: f32,\n}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer {
        for (symbols) |s| {
            if (s.children.len > 0) std.testing.allocator.free(s.children);
        }
        std.testing.allocator.free(symbols);
    }
    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqualStrings("Point", symbols[0].name);
    try std.testing.expectEqual(@as(usize, 2), symbols[0].children.len);
}

test "document symbols: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer std.testing.allocator.free(symbols);
    try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "document symbols: correct kinds" {
    const source: [:0]const u8 = "fn my_func() {} struct MyStruct { x: f32 }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, "my_func")) {
            try std.testing.expect(s.kind == .function);
        }
        if (std.mem.eql(u8, s.name, "MyStruct")) {
            try std.testing.expect(s.kind == .struct_type);
        }
    }
}

test "document symbols: unknown document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const symbols = try handler.computeDocumentSymbols("test://nonexistent.wgsl");
    try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "document symbols: entry point functions" {
    const source: [:0]const u8 =
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }
        \\@compute @workgroup_size(1) fn cs() {}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expectEqual(@as(usize, 3), symbols.len);
    try std.testing.expect(hasSymbol(symbols, "vs"));
    try std.testing.expect(hasSymbol(symbols, "fs"));
    try std.testing.expect(hasSymbol(symbols, "cs"));
}

test "document symbols: override declarations" {
    const source: [:0]const u8 = "@id(0) override WG_X: u32 = 8;\n@id(1) override WG_Y: u32 = 4;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expect(hasSymbol(symbols, "WG_X"));
    try std.testing.expect(hasSymbol(symbols, "WG_Y"));
}

test "document symbols: alias declarations" {
    const source: [:0]const u8 = "alias Float = f32;\nalias Vec = vec3f;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expect(hasSymbol(symbols, "Float"));
    try std.testing.expect(hasSymbol(symbols, "Vec"));
}

test "document symbols: order matches source" {
    const source: [:0]const u8 = "fn alpha() {} fn beta() {} fn gamma() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expectEqual(@as(usize, 3), symbols.len);
    try std.testing.expectEqualStrings("alpha", symbols[0].name);
    try std.testing.expectEqualStrings("beta", symbols[1].name);
    try std.testing.expectEqualStrings("gamma", symbols[2].name);
}

test "document symbols: struct with many members" {
    const source: [:0]const u8 =
        \\struct Vertex {
        \\  @location(0) position: vec3f,
        \\  @location(1) normal: vec3f,
        \\  @location(2) uv: vec2f,
        \\  @location(3) color: vec4f,
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const symbols = try ctx.handler.computeDocumentSymbols("test://file.wgsl");
    defer freeSymbols(symbols);
    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqual(@as(usize, 4), symbols[0].children.len);
}
