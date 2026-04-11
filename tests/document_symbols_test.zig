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
