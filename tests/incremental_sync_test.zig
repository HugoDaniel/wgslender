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

test "incremental sync: insert text" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    // Insert " -> f32" after "()"
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 6 },
        .end = .{ .line = 0, .character = 6 },
    }, " -> f32");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() -> f32 {}", source);
}

test "incremental sync: delete range" {
    const ctx = try setup("fn f() { let x = 1; }");
    defer teardown(ctx);
    // Delete "let x = 1; " (chars 9 to 20)
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 9 },
        .end = .{ .line = 0, .character = 20 },
    }, "");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() { }", source);
}

test "incremental sync: replace range" {
    const ctx = try setup("fn f() { let x = 1; }");
    defer teardown(ctx);
    // Replace "x" with "my_var"
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 13 },
        .end = .{ .line = 0, .character = 14 },
    }, "my_var");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() { let my_var = 1; }", source);
}

test "incremental sync: multi-line edit" {
    const ctx = try setup("fn f() {\n  let x = 1;\n}");
    defer teardown(ctx);
    // Insert a new line after "let x = 1;" (line 1, char 12 = end of "  let x = 1;")
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 1, .character = 12 },
        .end = .{ .line = 1, .character = 12 },
    }, "\n  let y = 2;");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() {\n  let x = 1;\n  let y = 2;\n}", source);
}

test "incremental sync: semantic edit invalidates analysis cache" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    _ = try ctx.handler.analyzeDocument("test://file.wgsl");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc.analysis != null);
    // Insert a new declaration — the non-trivia token stream changes, so
    // the handler must invalidate the cache.
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "const X = 1;\n");
    const doc2 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis == null);
}

test "incremental sync: zero-delta trivia edit keeps analysis cache hot" {
    // Only zero-delta trivia edits preserve the analysis cache: the
    // non-trivia token stream, AST spans, and symbol table are all
    // byte-for-byte identical, so the cached `AnalysisResult` stays
    // valid. Non-zero-delta trivia edits (insert/delete/length-changing
    // modifications) shift spans and therefore invalidate the cache
    // even though token *content* is unchanged.
    const ctx = try setup("// hello\nfn f() {}");
    defer teardown(ctx);
    const before = try ctx.handler.analyzeDocument("test://file.wgsl");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc.analysis != null);

    // Replace "hello" with "world" inside the comment — same byte count.
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 3 },
        .end = .{ .line = 0, .character = 8 },
    }, "world");

    const doc2 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis != null);
    // Cached pointer is unchanged — trivia shortcut preserves
    // `module_version`, so `analyzeDocument` returns the same object.
    try std.testing.expectEqual(before, doc2.analysis.?);
    try std.testing.expectEqualStrings("// world\nfn f() {}", doc2.source);
}

test "incremental sync: non-zero-delta trivia edit invalidates cache" {
    // Inserting a new trivia token shifts every downstream span — the
    // cached analysis's type/expr maps index off offsets that no longer
    // match. `module_version` bumps on the reparse and the handler drops
    // the cache. The next `analyzeDocument` call produces a fresh one.
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    const before = try ctx.handler.analyzeDocument("test://file.wgsl");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc.analysis != null);
    try std.testing.expectEqual(before, doc.analysis.?);

    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// comment\n");

    const doc2 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis == null);
    try std.testing.expectEqualStrings("// comment\nfn f() {}", doc2.source);
}

test "L1: literal edit in a function body sets doc.parse.reused = true" {
    const ctx = try setup("fn f() -> i32 { return 42; }");
    defer teardown(ctx);

    // Precondition: initial parse was full (reused=false).
    const doc0 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc0.parse != null);
    try std.testing.expect(!doc0.parse.?.reused);

    // Replace "42" (chars 23..25 on line 0) with "137". Anchor =
    // literal_expr, symbol-free → hot path → reused = true.
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 23 },
        .end = .{ .line = 0, .character = 25 },
    }, "137");

    const doc1 = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expectEqualStrings("fn f() -> i32 { return 137; }", doc1.source);
    try std.testing.expect(doc1.parse != null);
    try std.testing.expect(doc1.parse.?.reused);
}

test "L2: decl-level rename edit falls back; doc.parse.reused = false" {
    const ctx = try setup("const a = 1;\nconst b = 2;");
    defer teardown(ctx);

    // Rename the declarator `b` on line 1 → `bb`. Anchor bubbles up to
    // `let_decl`/`const_decl`, which is not symbol-free → fallback.
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 1, .character = 6 },
        .end = .{ .line = 1, .character = 7 },
    }, "bb");

    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expectEqualStrings("const a = 1;\nconst bb = 2;", doc.source);
    try std.testing.expect(doc.parse != null);
    try std.testing.expect(!doc.parse.?.reused);
}

test "incremental sync: edit at start of file" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// header\n");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("// header\nfn f() {}", source);
}

// =========================================================================
// Edge cases
// =========================================================================

test "incremental sync: edit at end of file" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 9 },
        .end = .{ .line = 0, .character = 9 },
    }, "\nfn g() {}");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() {}\nfn g() {}", source);
}

test "incremental sync: replace entire document" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 9 },
    }, "fn g() { let x = 1; }");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn g() { let x = 1; }", source);
}

test "incremental sync: sequential edits" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    // First edit: insert " -> f32"
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 6 },
        .end = .{ .line = 0, .character = 6 },
    }, " -> f32");
    // Second edit: insert "return 0.0; " inside body
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 15 },
        .end = .{ .line = 0, .character = 15 },
    }, " return 0.0; ");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fn f() -> f32 { return 0.0; }", source);
}

test "incremental sync: delete to empty" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 9 },
    }, "");
    const source = ctx.handler.getDocumentSource("test://file.wgsl") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", source);
}

test "incremental sync: unknown document no crash" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    // Should not crash on unknown document
    try handler.changeDocumentIncremental("test://nonexistent.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "text");
}

// =========================================================================
// Persistent parse state (doc.parse)
// =========================================================================

test "incremental sync: doc.parse is populated after openDocument" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    const parse = doc.parse orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("fn f() {}", parse.source);
    try std.testing.expectEqual(@as(usize, 1), parse.module.declarations.items.len);
}

test "incremental sync: doc.parse tracks source after incremental edit" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 9 },
        .end = .{ .line = 0, .character = 9 },
    }, "\nfn g() {}");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    const parse = doc.parse orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("fn f() {}\nfn g() {}", parse.source);
    try std.testing.expectEqualStrings(parse.source, doc.source);
    try std.testing.expectEqual(@as(usize, 2), parse.module.declarations.items.len);
}

test "incremental sync: doc.parse tracks source after full replace" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocument("test://file.wgsl", "const X = 1;");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    const parse = doc.parse orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("const X = 1;", parse.source);
    try std.testing.expectEqualStrings(parse.source, doc.source);
}

test "incremental sync: doc.parse survives trivia-only edit" {
    const ctx = try setup("fn f() {}");
    defer teardown(ctx);
    try ctx.handler.changeDocumentIncremental("test://file.wgsl", .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// header\n");
    const doc = ctx.handler.documents.getPtr("test://file.wgsl").?;
    const parse = doc.parse orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("// header\nfn f() {}", parse.source);
    try std.testing.expectEqualStrings(parse.source, doc.source);
}
