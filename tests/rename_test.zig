const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Edits = wgslender.Edits;
const Incremental = wgslender.Incremental;

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

test "rename: variable updates all occurrences" {
    const source: [:0]const u8 = "const x: f32 = 1.0; fn f() -> f32 { return x; }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 6) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "y");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    // Should have 2 edits: declaration + usage
    try std.testing.expectEqual(@as(usize, 2), edits.?.len);
    for (edits.?) |edit| {
        try std.testing.expectEqualStrings("y", edit.new_text);
    }
}

test "rename: reject keyword as new name" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "return");
    try std.testing.expect(edits == null);
}

test "rename: reject reserved word" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "class");
    try std.testing.expect(edits == null);
}

test "rename: reject __ prefix" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "__reserved");
    try std.testing.expect(edits == null);
}

test "rename: reject empty name" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "");
    try std.testing.expect(edits == null);
}

test "rename: prepareRename returns identifier range" {
    const source: [:0]const u8 = "fn my_func() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const range = try ctx.handler.prepareRename("test://file.wgsl", pos);
    try std.testing.expect(range != null);
    try std.testing.expectEqual(@as(u32, 3), range.?.start.character);
    try std.testing.expectEqual(@as(u32, 10), range.?.end.character);
}

test "rename: prepareRename on whitespace returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.prepareRename("test://file.wgsl", .{ .line = 0, .character = 2 });
    try std.testing.expect(result == null);
}

test "rename: struct updates type annotations" {
    const source: [:0]const u8 = "struct Pt { x: f32 } fn f(p: Pt) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 7) orelse return error.TestUnexpectedResult; // 'P' in "Pt"
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "Point");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    // Declaration + type ref = 2
    try std.testing.expectEqual(@as(usize, 2), edits.?.len);
}

test "isValidWgslIdentifier: valid names" {
    try std.testing.expect(Handler.isValidWgslIdentifier("x"));
    try std.testing.expect(Handler.isValidWgslIdentifier("my_var"));
    try std.testing.expect(Handler.isValidWgslIdentifier("_private"));
    try std.testing.expect(Handler.isValidWgslIdentifier("a123"));
}

test "isValidWgslIdentifier: invalid names" {
    try std.testing.expect(!Handler.isValidWgslIdentifier(""));
    try std.testing.expect(!Handler.isValidWgslIdentifier("__reserved"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("return"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("class"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("123abc"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("fn"));
}

// =========================================================================
// Edge cases
// =========================================================================

test "rename: function used across multiple call sites" {
    const source: [:0]const u8 =
        \\fn helper(x: f32) -> f32 { return x * 2.0; }
        \\fn a() -> f32 { return helper(1.0); }
        \\fn b() -> f32 { return helper(2.0); }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "util");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    // Declaration + 2 call sites = 3 edits
    try std.testing.expectEqual(@as(usize, 3), edits.?.len);
}

test "rename: reject all WGSL keywords" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    // Test several keywords
    for ([_][]const u8{ "if", "else", "for", "while", "loop", "switch", "case", "break", "continue", "return", "discard", "let", "var", "const", "struct", "alias", "fn", "override", "true", "false", "enable", "default" }) |kw| {
        const edits = try ctx.handler.computeRename("test://file.wgsl", pos, kw);
        try std.testing.expect(edits == null);
    }
}

test "rename: reject WGSL reserved words" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "abstract", "async", "await", "class", "enum", "import", "interface", "module", "namespace", "template", "typeof", "yield" }) |rw| {
        const edits = try ctx.handler.computeRename("test://file.wgsl", pos, rw);
        try std.testing.expect(edits == null);
    }
}

test "rename: single-character valid names" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const pos = Handler.offsetToLspPosition(source, 3) orelse return error.TestUnexpectedResult;
    const edits = try ctx.handler.computeRename("test://file.wgsl", pos, "g");
    try std.testing.expect(edits != null);
    defer std.testing.allocator.free(edits.?);
    try std.testing.expectEqual(@as(usize, 1), edits.?.len);
}

test "rename: underscore prefix valid (single underscore)" {
    try std.testing.expect(Handler.isValidWgslIdentifier("_x"));
    try std.testing.expect(Handler.isValidWgslIdentifier("_"));
    try std.testing.expect(!Handler.isValidWgslIdentifier("__x")); // double underscore reserved
}

// =========================================================================
// Retired tombstones
// =========================================================================

test "references and rename reject a retired direct target" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let stale: i32 = 1; _ = stale; return 0; }";

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // A length-changing edit inside the body takes the compound splice and
    // retires every declaration in the detached subtree.
    const ret_at: u32 = @intCast(std.mem.indexOf(u8, src, "return 0;").?);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = ret_at,
        .end = ret_at,
        .new_text = " ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    var retired: ?Ast.SymbolIndex = null;
    var fresh: ?Ast.SymbolIndex = null;
    for (state.module.symbols.items, 0..) |sym, i| {
        if (sym.kind != .let or !std.mem.eql(u8, sym.original_name, "stale")) continue;
        const ref: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (sym.flags.is_retired) retired = ref else fresh = ref;
    }
    try std.testing.expect(retired != null);
    try std.testing.expect(fresh != null);

    // The tombstone has no references — not even its old declaration site.
    const retired_refs = try Edits.findReferences(gpa, state.module, retired.?, true);
    defer gpa.free(retired_refs);
    try std.testing.expectEqual(@as(usize, 0), retired_refs.len);
    try std.testing.expect((try Edits.renameEdits(gpa, state.module, retired.?, "renamed")) == null);

    // The replacement still renames normally.
    const fresh_refs = try Edits.findReferences(gpa, state.module, fresh.?, true);
    defer gpa.free(fresh_refs);
    try std.testing.expectEqual(@as(usize, 2), fresh_refs.len);

    const edits = (try Edits.renameEdits(gpa, state.module, fresh.?, "renamed")) orelse
        return error.TestUnexpectedResult;
    defer gpa.free(edits);
    try std.testing.expectEqual(fresh_refs.len, edits.len);

    const rewritten = try Edits.applyEdits(gpa, state.source, edits);
    defer gpa.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "stale") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rewritten, "renamed"));
}

test "no-op renamer returns empty for a retired ref" {
    var symbols = [_]Ast.Symbol{
        .{ .original_name = "live", .kind = .function, .flags = .{} },
        .{ .original_name = "dead", .kind = .function, .flags = .{ .is_retired = true } },
    };
    var noop = wgslender.Renamer.NoOpRenamer.init(&symbols);
    noop.renamer.ptr = @ptrCast(&noop);
    try std.testing.expectEqualStrings(
        "live",
        noop.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(0))),
    );
    try std.testing.expectEqualStrings(
        "",
        noop.renamer.nameForSymbol(@as(Ast.SymbolIndex, @enumFromInt(1))),
    );
}

test "rename: position past end returns null" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const result = try ctx.handler.prepareRename("test://file.wgsl", .{ .line = 99, .character = 0 });
    try std.testing.expect(result == null);
}
