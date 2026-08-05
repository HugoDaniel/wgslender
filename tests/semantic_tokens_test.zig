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

test "semantic tokens: keywords are classified" {
    const source: [:0]const u8 = "fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have at least the "fn" keyword token (5 values per token)
    try std.testing.expect(data.len >= 5);
    // First token should be "fn" keyword at line 0, char 0, length 2
    try std.testing.expectEqual(@as(u32, 0), data[0]); // deltaLine
    try std.testing.expectEqual(@as(u32, 0), data[1]); // deltaStartChar
    try std.testing.expectEqual(@as(u32, 2), data[2]); // length
    try std.testing.expectEqual(@as(u32, 0), data[3]); // tokenType = keyword
}

test "semantic tokens: identifiers classified by symbol kind" {
    const source: [:0]const u8 = "fn my_func() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have at least "fn" and "my_func" tokens
    try std.testing.expect(data.len >= 10);
    // Second token is "my_func" (function, declaration)
    try std.testing.expectEqual(@as(u32, 7), data[7]); // length of "my_func"
    try std.testing.expectEqual(@as(u32, 1), data[8]); // tokenType = function
}

test "semantic tokens: number literals" {
    const source: [:0]const u8 = "const x: f32 = 3.14;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should contain the number token "3.14"
    var found_number = false;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 5) { // tokenType = number
            found_number = true;
            break;
        }
    }
    try std.testing.expect(found_number);
}

test "semantic tokens: comments" {
    const source: [:0]const u8 = "// a comment\nfn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // First token should be the comment
    try std.testing.expect(data.len >= 5);
    try std.testing.expectEqual(@as(u32, 7), data[3]); // tokenType = comment
}

test "semantic tokens: builtin function" {
    const source: [:0]const u8 = "fn f() { let x = sin(1.0); }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Find the "sin" token — should be function with defaultLibrary modifier
    var found_builtin = false;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 1 and data[i + 2] == 3) { // tokenType = function, length = 3 (sin)
            if (data[i + 4] & 4 != 0) { // defaultLibrary modifier
                found_builtin = true;
                break;
            }
        }
    }
    try std.testing.expect(found_builtin);
}

test "semantic tokens: empty file" {
    const source: [:0]const u8 = "";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "semantic tokens: decorator (@)" {
    const source: [:0]const u8 = "@vertex fn main() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // First token should be the '@' decorator
    try std.testing.expect(data.len >= 5);
    try std.testing.expectEqual(@as(u32, 8), data[3]); // tokenType = decorator
}

test "semantic tokens: unknown document returns empty" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    const data = try handler.computeSemanticTokens("test://nonexistent.wgsl");
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

// =========================================================================
// Edge cases
// =========================================================================

test "semantic tokens: struct declaration and members" {
    const source: [:0]const u8 = "struct S { x: f32 }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have: "struct" (keyword), "S" (struct), "x" (variable/member), "f32" (type)
    try std.testing.expect(data.len >= 15); // at least 3 tokens
}

test "semantic tokens: boolean literals" {
    const source: [:0]const u8 = "const a = true; const b = false;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have keyword tokens for true and false
    var found_true = false;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 0 and data[i + 2] == 4) { // keyword, length 4 = "true"
            found_true = true;
            break;
        }
    }
    try std.testing.expect(found_true);
}

test "semantic tokens: multi-line source" {
    const source: [:0]const u8 =
        \\const N: u32 = 10;
        \\fn compute() {
        \\  let x = sin(1.0);
        \\}
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have tokens across multiple lines
    try std.testing.expect(data.len >= 20);
    // Check deltaLine > 0 appears somewhere
    var has_line_delta = false;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i] > 0) {
            has_line_delta = true;
            break;
        }
    }
    try std.testing.expect(has_line_delta);
}

test "semantic tokens: nested block comment" {
    const source: [:0]const u8 = "/* outer /* inner */ still comment */ fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // First token should be the block comment
    try std.testing.expect(data.len >= 5);
    try std.testing.expectEqual(@as(u32, 7), data[3]); // tokenType = comment
}

test "semantic tokens: line comment" {
    const source: [:0]const u8 = "// line comment\nfn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len >= 5);
    try std.testing.expectEqual(@as(u32, 7), data[3]); // comment
}

test "semantic tokens: builtin type names" {
    const source: [:0]const u8 = "fn f(x: vec3f, y: mat4x4f) {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should classify vec3f and mat4x4f as type names
    var found_type = false;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 6) { // type_name
            found_type = true;
            break;
        }
    }
    try std.testing.expect(found_type);
}

test "semantic tokens: integer and float literals" {
    const source: [:0]const u8 = "const a: i32 = 42; const b: f32 = 3.14;";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    var number_count: u32 = 0;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 5) number_count += 1; // number
    }
    try std.testing.expect(number_count >= 2);
}

test "semantic tokens: control flow keywords" {
    const source: [:0]const u8 = "fn f() { if (true) { return; } else { discard; } }";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);
    // Should have keyword tokens for if, return, else, discard
    var keyword_count: u32 = 0;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        if (data[i + 3] == 0) keyword_count += 1; // keyword
    }
    try std.testing.expect(keyword_count >= 4); // fn, if, return, else, discard
}

// =========================================================================
// Scope-correct identifier resolution (plan 05, Block 3)
// =========================================================================

const SemanticToken = struct { length: u32, token_type: u32, modifiers: u32 };

/// Decode the delta-encoded token stream and return the token starting at
/// `offset`, or null if no token starts there.
fn tokenAtOffset(data: []const u32, source: [:0]const u8, offset: u32) ?SemanticToken {
    const want = Handler.offsetToLspPosition(source, offset) orelse return null;
    var line: u32 = 0;
    var char: u32 = 0;
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 5) {
        const delta_line = data[i];
        const delta_char = data[i + 1];
        line += delta_line;
        char = if (delta_line == 0) char + delta_char else delta_char;
        if (line == want.line and char == want.character) {
            return .{ .length = data[i + 2], .token_type = data[i + 3], .modifiers = data[i + 4] };
        }
    }
    return null;
}

/// Token type of the token starting at `offset`, or null if none starts there.
fn tokenTypeAtOffset(data: []const u32, source: [:0]const u8, offset: u32) ?u32 {
    const tok = tokenAtOffset(data, source, offset) orelse return null;
    return tok.token_type;
}

test "semantic tokens: a local reference is not resolved to a same-named parameter" {
    // `a`'s parameter `x` precedes `b`'s local `x` in module.symbols, so a
    // whole-module name scan returns the parameter for both.
    const source: [:0]const u8 =
        \\fn a(x: f32) -> f32 { return x; }
        \\fn b() { let x = 1.0; let y = x; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    // The reference under test: the final `x` in `let y = x;`.
    const ref_off: u32 = @intCast(std.mem.lastIndexOf(u8, source, "x;").?);
    const tok_type = tokenTypeAtOffset(data, source, ref_off) orelse
        return error.TestUnexpectedResult;
    // 4 = variable (a `let`), not 3 = parameter.
    try std.testing.expectEqual(@as(u32, 4), tok_type);
}

test "semantic tokens: a parameter reference stays a parameter" {
    const source: [:0]const u8 =
        \\fn a(x: f32) -> f32 { return x; }
        \\fn b() { let x = 1.0; let y = x; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    // `return x;` inside `a` — that `x` really is the parameter.
    const ref_off: u32 = @intCast(std.mem.indexOf(u8, source, "return x").? + 7);
    const tok_type = tokenTypeAtOffset(data, source, ref_off) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), tok_type); // parameter
}

test "semantic tokens: struct member names stay colored" {
    const source: [:0]const u8 =
        \\struct S { field: f32 }
        \\fn f() -> f32 { var s: S; return s.field; }
    ;
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    // The member name in `s.field` must still emit a token.
    const member_off: u32 = @intCast(std.mem.lastIndexOf(u8, source, "field").?);
    try std.testing.expect(tokenTypeAtOffset(data, source, member_off) != null);
}

// =========================================================================
// Token lengths are UTF-16 code units, not bytes
//
// `length` is the one place the protocol carries a width rather than a
// range, and it is counted in the negotiated `positionEncoding` — utf-16
// here. Byte lengths overshoot on every non-ASCII token.
// =========================================================================

const emoji = "\xF0\x9F\x8E\x89"; // 🎉 U+1F389 — 4 bytes, 2 UTF-16 code units.
const cjk = "\xE4\xB8\xAD"; // 中 U+4E2D — 3 bytes, 1 UTF-16 code unit.

test "semantic tokens: an ASCII comment's length is its byte length" {
    const source: [:0]const u8 = "// hello\nfn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    const tok = tokenAtOffset(data, source, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), tok.token_type); // comment
    try std.testing.expectEqual(@as(u32, 8), tok.length);
}

test "semantic tokens: a comment's length counts UTF-16 code units" {
    const source: [:0]const u8 = "// a " ++ emoji ++ " " ++ cjk ++ "\nfn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    const tok = tokenAtOffset(data, source, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), tok.token_type); // comment
    // "// a " (5) + 🎉 (2) + " " (1) + 中 (1) = 9 units, over 13 bytes.
    try std.testing.expectEqual(@as(u32, 9), tok.length);
}

test "semantic tokens: a block comment's length counts UTF-16 code units" {
    const source: [:0]const u8 = "/*" ++ emoji ++ cjk ++ "*/ fn f() {}";
    const ctx = try setup(source);
    defer teardown(ctx);
    const data = try ctx.handler.computeSemanticTokens("test://file.wgsl");
    defer std.testing.allocator.free(data);

    const tok = tokenAtOffset(data, source, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), tok.token_type); // comment
    // "/*" (2) + 🎉 (2) + 中 (1) + "*/" (2) = 7 units, over 11 bytes.
    try std.testing.expectEqual(@as(u32, 7), tok.length);
}
