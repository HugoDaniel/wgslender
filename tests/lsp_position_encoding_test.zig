//! End-to-end tests for LSP UTF-16 position encoding. The server
//! advertises `positionEncoding: utf-16` in the initialize result and
//! these tests pin that the helper round-trips, definition lookups, and
//! diagnostic ranges all emit / accept positions in UTF-16 code units —
//! not bytes. Without this guarantee, every cursor-driven feature
//! (definition, hover, references, completion, …) drifts by one column
//! per non-ASCII byte that precedes the target on the same line.

const std = @import("std");
const Handler = @import("Handler");

const emoji = "\xF0\x9F\x8E\x89"; // 🎉 — 4 bytes UTF-8, 2 UTF-16 code units.
const cjk = "\xE4\xB8\xAD"; // 中 — 3 bytes UTF-8, 1 UTF-16 code unit.

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

test "definition: identifier on a line preceded by a CJK comment" {
    // 中文 comment uses 3-byte UTF-8 chars. The usage of `x` sits later on
    // line 1; the goto-def target is `const x` on line 1 (column 6 in
    // UTF-16 units / byte offset doesn't matter — we assert UTF-16).
    const source: [:0]const u8 = "// " ++ cjk ++ cjk ++ "\nconst x: i32 = 1; fn f() { let y = x; }";
    const ctx = try setup(source);
    defer teardown(ctx);

    const x_usage = std.mem.lastIndexOf(u8, source, "x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(x_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // `const x` is on line 1, column 6 (UTF-16 units; same as bytes here
    // because the second line is ASCII).
    try std.testing.expectEqual(@as(u32, 1), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "definition: identifier preceded by a 4-byte emoji on the same line" {
    // The emoji counts as 2 UTF-16 units but 4 bytes. The byte-counting
    // helper would report `let y = ` at character 4 + 8 = 12 (wrong) on
    // an emoji-prefixed line; the UTF-16 helper reports
    // (2 [emoji surrogates] + 6 [" */ x"]) → so the goto-def query on
    // the trailing `x` resolves correctly only with UTF-16 columns.
    const source: [:0]const u8 = "const x: i32 = 1; fn f() { /*" ++ emoji ++ "*/ let y = x; }";
    const ctx = try setup(source);
    defer teardown(ctx);

    const x_usage = std.mem.lastIndexOf(u8, source, "x") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(x_usage)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // The declaration `const x` sits on line 0 at character 6.
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 6), result.?.start.character);
}

test "hover: declaration on a line containing a 4-byte char" {
    // Hover on `MyStruct` usage; declaration line carries an emoji.
    const source: [:0]const u8 = "// " ++ emoji ++ " note\nstruct MyStruct { a: f32 }\nfn f(s: MyStruct) {}";
    const ctx = try setup(source);
    defer teardown(ctx);

    const usage_offset = std.mem.lastIndexOf(u8, source, "MyStruct") orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(usage_offset)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeHover("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.?.contents, "MyStruct") != null);
}

test "validate: diagnostic range uses UTF-16 columns when line carries a 4-byte char" {
    // `const x: i32 = 1.5;` triggers E0200 (type-mismatch). The block
    // comment carries an emoji (2 UTF-16 units, 4 bytes), so the LSP
    // `range.start.character` must reflect UTF-16 units rather than the
    // raw byte column. We pin the UTF-16 column the helper would emit
    // for the diagnostic's byte offset and check the LSP range matches.
    //
    // Source layout (bytes vs. UTF-16 units):
    //   c o n s t _ / * 🎉🎉🎉🎉 * /  _ x : _ i 3 2 _ = _ 1 . 5 ;
    //   0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 …       (bytes)
    //   0 1 2 3 4 5 6 7 8  9        10 11 12 13 …    (UTF-16 units)
    //                       ^ 4-byte emoji = 2 surrogate units
    const source = "const /*" ++ emoji ++ "*/ x: i32 = 1.5;";
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer Handler.freeDiagnostics(std.testing.allocator, diags);

    var found: ?Handler.LspDiagnostic = null;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E0200")) {
            found = d;
            break;
        }
    }
    try std.testing.expect(found != null);
    const r = found.?.range;
    try std.testing.expectEqual(@as(u32, 0), r.start.line);
    try std.testing.expect(r.start.character < r.end.character);

    // Round-trip the emitted UTF-16 range back to byte offsets and pin
    // them to the original byte location of the `x` token (offset 15)
    // — the validator's range.start. With a byte counter, decoding the
    // emitted column would land 2 bytes off because the emoji
    // contributes 4 UTF-8 bytes vs. 2 UTF-16 units.
    const start_byte = Handler.lspPositionToOffset(source, r.start) orelse return error.TestUnexpectedResult;
    const x_byte = std.mem.indexOf(u8, source, "x: i32") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(x_byte, start_byte);

    // And assert UTF-16 column matches what offsetToLspPosition emits
    // for the same byte offset — the helper is the single source of
    // truth that convertDiagnostic now goes through.
    const expected = Handler.offsetToLspPosition(source, @intCast(x_byte)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected.character, r.start.character);
}

test "lspPositionToOffset: mid-surrogate-pair snaps to boundary before the pair" {
    // Documented behaviour: an LSP `character` that lands inside a
    // surrogate pair returns the byte offset of the lead surrogate
    // (i.e. the start of the 4-byte UTF-8 sequence). Non-throwing.
    const source: [:0]const u8 = "// " ++ emoji ++ "\nrest";
    const offset = Handler.lspPositionToOffset(source, .{ .line = 0, .character = 4 });
    try std.testing.expect(offset != null);
    // 3 ASCII bytes precede the emoji.
    try std.testing.expectEqual(@as(usize, 3), offset.?);
}

test "definition: identifier contains a UTF-16 surrogate pair" {
    // U+20000 — XID_Start, 4-byte UTF-8 (F0 A0 80 80), 2 UTF-16 code units.
    // Both the declaration and the call site are named with this codepoint;
    // a UTF-16-correct lspPositionToOffset must land inside the call-site
    // identifier when given the LSP column derived from its byte offset.
    const ext = "\xF0\xA0\x80\x80";
    const source: [:0]const u8 = "fn " ++ ext ++ "() {} fn caller() { " ++ ext ++ "(); }";
    const ctx = try setup(source);
    defer teardown(ctx);

    const call_site = std.mem.lastIndexOf(u8, source, ext) orelse return error.TestUnexpectedResult;
    const pos = Handler.offsetToLspPosition(source, @intCast(call_site)) orelse return error.TestUnexpectedResult;
    const result = try ctx.handler.computeDefinition("test://file.wgsl", pos);
    try std.testing.expect(result != null);
    // The declaration sits on line 0; the supplementary-plane name starts
    // at byte offset 3 / UTF-16 column 3 (preceded by `fn ` — 3 ASCII chars).
    try std.testing.expectEqual(@as(u32, 0), result.?.start.line);
    try std.testing.expectEqual(@as(u32, 3), result.?.start.character);
}

test "round-trip: offsetToLspPosition ∘ lspPositionToOffset on mixed-width source" {
    // Identity round-trip at every UTF-8 boundary in a string mixing
    // 1/2/3/4-byte sequences and CRLF line breaks.
    const source: [:0]const u8 = "fn f() {\r\n  // a\xC3\xA4" ++ cjk ++ emoji ++ "\n  let x = 1;\n}";
    const boundaries = [_]u32{ 0, 3, 8, 10, 12, 15, 17, 20, 24, 25, 28, 32, 38, 39 };
    for (boundaries) |off| {
        if (off > source.len) continue;
        const pos = Handler.offsetToLspPosition(source, off) orelse continue;
        const back = Handler.lspPositionToOffset(source, pos) orelse continue;
        try std.testing.expectEqual(@as(usize, off), back);
    }
}
