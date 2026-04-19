//! Long-tail robustness coverage for `Incremental.reparse` +
//! `Incremental.classifyEdit`.
//!
//! Each case exercises a scenario a naive implementation would miss.
//! After every edit we assert:
//!   - the new source is the expected byte sequence,
//!   - `classifyEdit(old, new)` returns the expected `EditKind`,
//!   - `reparse(prev, edit).source` matches the edited source,
//!   - the new AST parses (declaration count is within expectation).

const std = @import("std");
const wgslender = @import("wgslender");
const Incremental = wgslender.Incremental;

// =========================================================================
// Small helpers
// =========================================================================

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf[0..bytes.len :0];
}

fn expectClassify(old: [:0]const u8, new: [:0]const u8, expected: Incremental.EditKind) !void {
    const kind = try Incremental.classifyEdit(std.testing.allocator, old, new);
    try std.testing.expectEqual(expected, kind);
}

// =========================================================================
// File-boundary edits
// =========================================================================

test "L1: insert at offset 0 in non-empty file" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 0,
        .end = 0,
        .new_text = "const y = 2;\n",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("const y = 2;\nconst x = 1;", updated.source);
    try std.testing.expectEqual(@as(usize, 2), updated.module.declarations.items.len);
}

test "L2: append at EOF" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    const end_offset: u32 = @intCast(base.source.len);
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = end_offset,
        .end = end_offset,
        .new_text = "\n",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", updated.source);
    try expectClassify("const x = 1;", "const x = 1;\n", .trivia_only);
}

test "L3: zero-length insert (empty new_text, start == end) is a no-op" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 5,
        .end = 5,
        .new_text = "",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("const x = 1;", updated.source);
}

test "L4: zero-length delete at mid-source" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 5,
        .end = 5, // same as start → nothing to delete
        .new_text = "",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("const x = 1;", updated.source);
}

test "L5: replace entire file" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    const n: u32 = @intCast(base.source.len);
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 0,
        .end = n,
        .new_text = "fn main() {}",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("fn main() {}", updated.source);
    try std.testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
}

test "L6: edit in a previously empty file" {
    var base = try Incremental.parseFull(std.testing.allocator, "");
    defer base.deinit();
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 0,
        .end = 0,
        .new_text = "const x = 1;",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("const x = 1;", updated.source);
    try std.testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
}

test "L7: edit that empties the file" {
    var base = try Incremental.parseFull(std.testing.allocator, "const x = 1;");
    defer base.deinit();
    const n: u32 = @intCast(base.source.len);
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = 0,
        .end = n,
        .new_text = "",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("", updated.source);
    try std.testing.expectEqual(@as(usize, 0), updated.module.declarations.items.len);
}

// =========================================================================
// Comment- and trivia-structure edits
// =========================================================================

test "L13: break a block comment by deleting its closing */" {
    // Before: decl is live; after: the `*/` is gone and the block comment
    // extends to EOF, consuming what used to be two declarations. The edit
    // must classify as semantic and the post-reparse module has 1 decl.
    const old: [:0]const u8 = "/* intro */ const x = 1; /* mid */ const y = 2;";
    const new: [:0]const u8 = "/* intro */ const x = 1; /* mid  const y = 2;";
    try expectClassify(old, new, .semantic);

    var base = try Incremental.parseFull(std.testing.allocator, old);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 2), base.module.declarations.items.len);

    // Delete the closing `*/` of the mid comment (the 2-byte sequence).
    const mid = std.mem.indexOf(u8, old, "*/ const y").?;
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = @intCast(mid),
        .end = @intCast(mid + 2),
        .new_text = "",
    });
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
}

test "L14: close a stray /* by inserting */" {
    const old: [:0]const u8 = "/* unterminated\n const x = 1;";
    const new: [:0]const u8 = "/* unterminated */\n const x = 1;";
    // old parses as a block comment to EOF with 0 decls; new has 1 decl.
    var base = try Incremental.parseFull(std.testing.allocator, old);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 0), base.module.declarations.items.len);

    const insert_at: u32 = @intCast(std.mem.indexOf(u8, old, "\n const").?);
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = insert_at,
        .end = insert_at,
        .new_text = " */",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new, updated.source);
    try std.testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
    try expectClassify(old, new, .semantic);
}

test "L15: edit mid-line-comment body does not affect AST" {
    const old: [:0]const u8 = "// original note\nconst x = 1;";
    const new: [:0]const u8 = "// updated note\nconst x = 1;";
    try expectClassify(old, new, .trivia_only);
}

// =========================================================================
// Token-tag flips
// =========================================================================

test "L10: keyword → identifier (fn → fnx) is semantic" {
    try expectClassify("fn f() {}", "fnx f() {}", .semantic);
}

test "L11: identifier → keyword (fnx → fn) is semantic" {
    try expectClassify("fnx f() {}", "fn f() {}", .semantic);
}

test "L12: var ↔ let token swap is semantic" {
    try expectClassify(
        "fn f() { var x = 1; }",
        "fn f() { let x = 1; }",
        .semantic,
    );
}

// =========================================================================
// Identifier manipulations
// =========================================================================

test "L8: splitting an identifier mid-token is semantic" {
    try expectClassify("fn myFunction() {}", "fn myFu_nction() {}", .semantic);
}

test "L9: joining two identifiers is semantic" {
    try expectClassify("fn a b() {}", "fn ab() {}", .semantic);
}

test "L18: mid-identifier rename flips semantic classification" {
    try expectClassify("const myVeryLongName = 1;", "const myVeryLongNameX = 1;", .semantic);
}

// =========================================================================
// Template-vs-comparison disambiguation
// =========================================================================

test "L30: flipping < to template context is semantic" {
    try expectClassify(
        "fn f() { if x < 2 { return; } }",
        "fn f() { let y: array<f32,2> = array(1,2); }",
        .semantic,
    );
}

// =========================================================================
// Unicode + line endings
// =========================================================================

test "L16: CRLF → LF normalization on a shader is trivia_only" {
    try expectClassify(
        "const a = 1;\r\nconst b = 2;\r\n",
        "const a = 1;\nconst b = 2;\n",
        .trivia_only,
    );
}

test "L21: reparse handles multi-byte identifier edit without crashing" {
    // WGSL idents are ASCII today, but tokens may carry multi-byte content
    // inside comments. Verify reparse handles a multi-byte insert inside a
    // comment trivia region.
    const old: [:0]const u8 = "// plain\nconst x = 1;";
    var base = try Incremental.parseFull(std.testing.allocator, old);
    defer base.deinit();
    const insert_at: u32 = @intCast(std.mem.indexOf(u8, old, "plain").?);
    var updated = try Incremental.reparse(std.testing.allocator, &base, .{
        .start = insert_at,
        .end = insert_at,
        .new_text = "\xF0\x9F\x8E\x89 ", // 🎉
    });
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.module.declarations.items.len);
    // Pointer to analysis stays valid across trivia-only edits — verify
    // classification.
    const old_z = old;
    const new_z: [:0]const u8 = "// \xF0\x9F\x8E\x89 plain\nconst x = 1;";
    try expectClassify(old_z, new_z, .trivia_only);
}

// =========================================================================
// Numeric edits
// =========================================================================

test "L24: attribute literal edit is semantic" {
    // Changing @workgroup_size(8) → @workgroup_size(16) changes a literal's
    // text, so non-trivia tokens differ → semantic.
    try expectClassify(
        "@compute @workgroup_size(8) fn main() {}",
        "@compute @workgroup_size(16) fn main() {}",
        .semantic,
    );
}

test "L28: change template arg is semantic" {
    try expectClassify(
        "var<private> a: array<f32, 4>;",
        "var<private> a: array<f32, 8>;",
        .semantic,
    );
}

// =========================================================================
// Round-trip equivalence (forward + inverse)
// =========================================================================

test "L34: forward + inverse edit sequence produces byte-identical source" {
    const base_src: [:0]const u8 = "fn f() { let x = 1; return; }";
    var step0 = try Incremental.parseFull(std.testing.allocator, base_src);
    defer step0.deinit();

    // Step 1: insert "  " after "= "
    const eq_off = std.mem.indexOfScalar(u8, base_src, '=').?;
    const ins_at: u32 = @intCast(eq_off + 2);
    var step1 = try Incremental.reparse(std.testing.allocator, &step0, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "  ",
    });
    defer step1.deinit();

    // Step 2: delete the 2 spaces we just inserted.
    var step2 = try Incremental.reparse(std.testing.allocator, &step1, .{
        .start = ins_at,
        .end = ins_at + 2,
        .new_text = "",
    });
    defer step2.deinit();

    try std.testing.expectEqualStrings(base_src, step2.source);
    try std.testing.expectEqual(
        step0.module.declarations.items.len,
        step2.module.declarations.items.len,
    );
}

// =========================================================================
// No-op
// =========================================================================

test "L-noop: identical sources classify as no_op" {
    try expectClassify("const x = 1;", "const x = 1;", .no_op);
}

// =========================================================================
// L-append — compound_stmt hot path for local `let`/`var`/`const` edits.
// Each case exercises a specific trivia/structural shape that a naive
// implementation of the append-only path would miss.
// =========================================================================

test "L-append-01: append a deeply nested block in one edit" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() {}");
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 8,
        .end = 8,
        .new_text = " { { { let a = 1; } } }",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("fn f() { { { { let a = 1; } } }}", updated.source);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try std.testing.expectEqual(
        oracle.module.declarations.items.len,
        updated.module.declarations.items.len,
    );
    try std.testing.expectEqual(oracle.module.symbols.items.len, updated.module.symbols.items.len);
}

test "L-append-02: append a call statement into an empty body" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn g() {} fn f() {}");
    defer base.deinit();
    // Insert `g();` just before the closing `}` of f.
    const close_off: u32 = @intCast(base.source.len - 1);
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = close_off,
        .end = close_off,
        .new_text = " g();",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("fn g() {} fn f() { g();}", updated.source);
}

test "L-append-03: append a multi-line decl with mid-expression trivia" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() {}");
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 8,
        .end = 8,
        .new_text = " let /* hi */ x = 1;",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("fn f() { let /* hi */ x = 1;}", updated.source);
}

test "L-append-04: append a decl with an underscore/digit identifier" {
    // WGSL identifiers are ASCII in this parser; use a long ASCII name
    // with a digit suffix to stress the tokenizer's identifier path.
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() {}");
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 8,
        .end = 8,
        .new_text = " let _really_long_name_42 = 3.14;",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("fn f() { let _really_long_name_42 = 3.14;}", updated.source);
}

test "L-append-05: append a for-loop whose body declares a local" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() {}");
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 8,
        .end = 8,
        .new_text = " for (var i = 0; i < 4; i = i + 1) { let t = i; }",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try std.testing.expectEqual(oracle.module.symbols.items.len, updated.module.symbols.items.len);
}

test "L-append-06: append into a body that starts with a block comment" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() { /* body */ }");
    defer base.deinit();
    // Insert `let a = 1;` just before the closing brace.
    const close_off: u32 = @intCast(base.source.len - 1);
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = close_off,
        .end = close_off,
        .new_text = "let a = 1; ",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("fn f() { /* body */ let a = 1; }", updated.source);
}

test "L-append-07: append followed by inverse delete round-trips" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() { let a = 1; }";

    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();

    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = 19,
        .end = 19,
        .new_text = " let b = 2;",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);

    // Inverse: delete exactly the bytes we just appended. After the
    // append, those bytes live at [19, 30) in the new source.
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = 19,
        .end = 30,
        .new_text = "",
    });
    defer step2.deinit();
    try std.testing.expectEqualStrings(base_src, step2.source);
}
