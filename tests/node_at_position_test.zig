const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

fn analyzeSource(source: [:0]const u8) !*wgslender.Validator.AnalysisResult {
    const result = try std.testing.allocator.create(wgslender.Validator.AnalysisResult);
    errdefer std.testing.allocator.destroy(result);
    result.* = try wgslender.analyzeWithOptions(std.testing.allocator, source, .{});
    return result;
}

fn cleanup(result: *wgslender.Validator.AnalysisResult) void {
    result.deinit(std.testing.allocator);
    std.testing.allocator.destroy(result);
}

test "findNodeAtOffset: cursor on variable usage returns ident" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() { let y = x; }";
    //                                                            offset 38 ^
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    // 'x' usage inside function body at "let y = x"
    // Find the second 'x' in source (the usage)
    const x_usage_offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "x").?);
    const node = Handler.findNodeAtOffset(module, x_usage_offset);
    switch (node) {
        .ident => |id| {
            try std.testing.expectEqualStrings("x", id.name);
            try std.testing.expect(id.ref.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor on function name in declaration" {
    const source: [:0]const u8 = "fn my_func() {}";
    //                               ^-- offset 3
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    const node = Handler.findNodeAtOffset(module, 3);
    switch (node) {
        .decl_name => |dn| {
            try std.testing.expect(dn.sym_idx.isValid());
            const sym = module.symbols.items[dn.sym_idx.index()];
            try std.testing.expectEqualStrings("my_func", sym.original_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor on struct member access" {
    // Simple test: access a struct member
    const source: [:0]const u8 = "struct S { val: f32 } fn f(s: S) -> f32 { return s.val; }";
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    // Find ".val" in source
    const dot_pos = std.mem.indexOf(u8, source, ".val") orelse return error.TestUnexpectedResult;
    const member_offset: u32 = @intCast(dot_pos + 1); // skip the dot, pointing at 'v' in "val"
    try std.testing.expectEqual(@as(u8, 'v'), source[member_offset]);

    const node = Handler.findNodeAtOffset(module, member_offset);
    switch (node) {
        .member_access => |ma| {
            try std.testing.expectEqualStrings("val", ma.member);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor on type annotation" {
    const source: [:0]const u8 = "struct MyStruct { x: f32 } var v: MyStruct;";
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    // "MyStruct" in "var v: MyStruct" — find the second occurrence
    const type_offset: u32 = @intCast(std.mem.lastIndexOf(u8, source, "MyStruct").?);
    const node = Handler.findNodeAtOffset(module, type_offset);
    switch (node) {
        .type_ref => |tr| {
            try std.testing.expectEqualStrings("MyStruct", tr.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor on whitespace returns none" {
    const source: [:0]const u8 = "fn f() { }";
    //                                ^ offset 5 is the space before '('
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    // Offset 2 is a space between "fn" and "f"
    const node = Handler.findNodeAtOffset(module, 2);
    try std.testing.expect(node == .none);
}

test "findNodeAtOffset: cursor on struct declaration name" {
    const source: [:0]const u8 = "struct Point { x: f32, y: f32 }";
    //                                  ^-- offset 7
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    const node = Handler.findNodeAtOffset(module, 7);
    switch (node) {
        .decl_name => |dn| {
            const sym = module.symbols.items[dn.sym_idx.index()];
            try std.testing.expectEqualStrings("Point", sym.original_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor on parameter name in function" {
    const source: [:0]const u8 = "fn add(a: f32, b: f32) -> f32 { return a + b; }";
    //                                   ^-- offset 7, 'a' parameter
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    const node = Handler.findNodeAtOffset(module, 7);
    switch (node) {
        .decl_name => |dn| {
            const sym = module.symbols.items[dn.sym_idx.index()];
            try std.testing.expectEqualStrings("a", sym.original_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor at identifier boundary (last char)" {
    const source: [:0]const u8 = "fn abc() {}";
    //                                  ^-- offset 5 = 'c', last char of "abc"
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    // "abc" starts at offset 3, length 3, so valid range is [3,6)
    const node = Handler.findNodeAtOffset(module, 5);
    switch (node) {
        .decl_name => |dn| {
            const sym = module.symbols.items[dn.sym_idx.index()];
            try std.testing.expectEqualStrings("abc", sym.original_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNodeAtOffset: cursor just past identifier returns none" {
    const source: [:0]const u8 = "fn abc() {}";
    //                                   ^-- offset 6 = '(', just after "abc"
    const result = try analyzeSource(source);
    defer cleanup(result);
    const module = result.module orelse return error.TestUnexpectedResult;
    const node = Handler.findNodeAtOffset(module, 6);
    try std.testing.expect(node == .none);
}
