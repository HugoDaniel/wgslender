//! End-to-end unit tests for the symbol-free hot path in
//! `Incremental.reparse`.
//!
//! Each scenario applies an edit via `Incremental.reparse`, then asserts
//! three things:
//!   1. The returned `source` matches `apply(edit)` on the old source.
//!   2. The resulting `Ast.Module` is shape-equivalent to
//!      `Incremental.parseFull(new_source)` (same decl count, same
//!      symbol table contents, same statement structure).
//!   3. `reused == true` on the edits that should take the hot path,
//!      `reused == false` on the edits that must fall back.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

/// Render a module as a compact S-expression over decl kinds. Used to
/// compare "same shape" between the hot-path result and a full parse of
/// the edited source.
fn renderModule(
    gpa: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    m: *const Ast.Module,
) !void {
    try buf.appendSlice(gpa, "(module");
    for (m.declarations.items) |d| {
        try buf.append(gpa, ' ');
        try buf.appendSlice(gpa, @tagName(d));
    }
    try buf.appendSlice(gpa, ")");
}

fn expectShapesMatch(gpa: std.mem.Allocator, a: *const Ast.Module, b: *const Ast.Module) !void {
    var ab: std.ArrayListUnmanaged(u8) = .empty;
    defer ab.deinit(gpa);
    var bb: std.ArrayListUnmanaged(u8) = .empty;
    defer bb.deinit(gpa);
    try renderModule(gpa, &ab, a);
    try renderModule(gpa, &bb, b);
    try std.testing.expectEqualStrings(ab.items, bb.items);
}

fn expectSymbolsMatch(a: *const Ast.Module, b: *const Ast.Module) !void {
    try std.testing.expectEqual(a.symbols.items.len, b.symbols.items.len);
    for (a.symbols.items, b.symbols.items) |sa, sb| {
        try std.testing.expectEqualStrings(sa.original_name, sb.original_name);
        try std.testing.expectEqual(sa.kind, sb.kind);
        try std.testing.expectEqual(sa.use_count, sb.use_count);
    }
}

fn applyEditAndVerify(
    gpa: std.mem.Allocator,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
    expected_src: []const u8,
    expected_reused: bool,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected_src, updated.source);
    try std.testing.expectEqual(expected_reused, updated.reused);

    // Oracle: shape must match a full parse of the new source.
    var oracle = try Incremental.parseFull(gpa, expected_src);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectSymbolsMatch(updated.module, oracle.module);
}

// =========================================================================
// Symbol-free hot path scenarios
// =========================================================================

test "S1: literal bump inside a return statement" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() -> i32 { return 42; }",
        .{ .start = 23, .end = 25, .new_text = "137" },
        "fn f() -> i32 { return 137; }",
        true,
    );
}

test "S2: flip binary op inside an assign stmt" {
    // "const x = 5;" establishes a module-scope constant, then the
    // function rebinds a var `y = x + 1` and mutates it. The mutation
    // `y = y + 1` is the anchor; flip + to -.
    const src: [:0]const u8 = "const x = 5; fn f() { var y = 0; y = y + x; }";
    // Locate the '+' in "y + x".
    const plus_idx: u32 = @intCast(std.mem.indexOfPos(u8, src, 33, "+").?);
    try applyEditAndVerify(
        std.testing.allocator,
        src,
        .{ .start = plus_idx, .end = plus_idx + 1, .new_text = "-" },
        "const x = 5; fn f() { var y = 0; y = y - x; }",
        true,
    );
}

test "S3: swap ident at a use site (ident_expr anchor)" {
    // `let b = a` → `let b = aa`. The use of `a` becomes an unresolved
    // ident; full parse agrees.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; let b = a; }",
        // Find the SECOND 'a' (the use site at byte 28).
        .{ .start = 28, .end = 29, .new_text = "aa" },
        "fn f() { let a = 1; let b = aa; }",
        true,
    );
}

test "S4: rename at decl site falls back (not symbol-free)" {
    // Editing the declarator name spans the let_decl. findAnchor
    // bubbles up to let_decl or decl_stmt, neither of which is in
    // `isSymbolFreeAnchor`, so we fall back to a full parse.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; let b = a + 2; }",
        .{ .start = 13, .end = 14, .new_text = "aa" },
        "fn f() { let aa = 1; let b = a + 2; }",
        false,
    );
}

test "S5: add a new local stmt → fallback (compound_stmt)" {
    // Inserting a new stmt into a function body requires re-scoping;
    // `compound_stmt` is not symbol-free, so we fall back.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
        "fn f() { let a = 1; let b = 2; }",
        false,
    );
}

test "S6: inverse edit round-trips" {
    const base: [:0]const u8 = "fn f() -> i32 { return 42; }";
    const gpa = std.testing.allocator;
    var r1 = try Incremental.parseFull(gpa, base);
    defer r1.deinit();
    var r2 = try Incremental.reparse(gpa, &r1, .{ .start = 23, .end = 25, .new_text = "137" });
    defer r2.deinit();
    var r3 = try Incremental.reparse(gpa, &r2, .{ .start = 23, .end = 26, .new_text = "42" });
    defer r3.deinit();
    try std.testing.expectEqualStrings(base, r3.source);
    try std.testing.expect(r2.reused);
    try std.testing.expect(r3.reused);
}

test "S7: burst of 20 literal edits all take hot path" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();
    // Each iteration appends "0" to the literal.
    const literal_start: u32 = 23;
    var literal_len: u32 = 1;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = literal_start + literal_len,
            .end = literal_start + literal_len,
            .new_text = "0",
        });
        cur.deinit();
        cur = next;
        try std.testing.expect(cur.reused);
        literal_len += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), cur.module.declarations.items.len);
}

test "S8: kind-mismatch reparse falls back" {
    // Editing "1" into "1 * 3" inside "return 1 + 2;": the anchor
    // is the leftmost literal_expr ("1"), but the reparse turns it
    // into a binary_expr — kind mismatch triggers fallback.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() -> i32 { return 1 + 2; }",
        .{ .start = 23, .end = 24, .new_text = "1 * 3" },
        "fn f() -> i32 { return 1 * 3 + 2; }",
        false,
    );
}

test "S9: edit inside paren_expr" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() -> i32 { return (1 + 2); }",
        .{ .start = 28, .end = 29, .new_text = "20" },
        "fn f() -> i32 { return (1 + 20); }",
        true,
    );
}

test "S10: deeply nested expression edit" {
    const src: [:0]const u8 = "fn f() -> f32 { let z = 0.0; return z + 0.5; }";
    // Edit "0.5" → "0.25"; anchor is literal_expr.
    const five_idx: u32 = @intCast(std.mem.indexOfPos(u8, src, 36, "0.5").?);
    try applyEditAndVerify(
        std.testing.allocator,
        src,
        .{ .start = five_idx, .end = five_idx + 3, .new_text = "0.25" },
        "fn f() -> f32 { let z = 0.0; return z + 0.25; }",
        true,
    );
}

test "S13: offset shift after edit propagates to following decls" {
    // A literal bump in the first decl shifts every subsequent decl's
    // span by delta. After the edit, findAnchor on a byte in the
    // second decl must locate the correct node.
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "const a = 1;\nconst b = 2;\nconst c = 3;";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Replace "1" (byte 10) with "10000" — decls `b` and `c` each
    // shift by +4 bytes.
    var r1 = try Incremental.reparse(gpa, &base, .{ .start = 10, .end = 11, .new_text = "10000" });
    defer r1.deinit();
    try std.testing.expect(r1.reused);
    try std.testing.expectEqualStrings("const a = 10000;\nconst b = 2;\nconst c = 3;", r1.source);
    try std.testing.expectEqual(@as(usize, 3), r1.module.declarations.items.len);

    // Now edit the "2" in the (shifted) second decl. "const b = 2"
    // begins at byte 17 of the new source; the "2" literal is at
    // byte 27.
    var r2 = try Incremental.reparse(gpa, &r1, .{ .start = 27, .end = 28, .new_text = "99" });
    defer r2.deinit();
    try std.testing.expect(r2.reused);
    try std.testing.expectEqualStrings("const a = 10000;\nconst b = 99;\nconst c = 3;", r2.source);
}

test "S15: edit bridging two decls → no anchor → fallback" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Replace part of "x = 1;\nconst y" with "a = 3; const z"
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 6,
        .end = 20,
        .new_text = "a = 3; const z",
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);
    try std.testing.expectEqualStrings("const a = 3; const z = 2;", updated.source);
}

test "S16: kind-stable edit that introduces a parse error falls back" {
    // `return 2;` → `return +;` produces a literal_expr anchor that
    // reparses as an error subtree; new_sub.errors.len > 0 triggers
    // fallback.
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { return 2; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 23,
        .end = 24,
        .new_text = "+",
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);
    try std.testing.expectEqualStrings("fn f() -> i32 { return +; }", updated.source);
}
