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
const ast_equal = @import("ast_equal.zig");

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
    // Oracle is `b` (from parseFull). `a` came from incremental splice;
    // the compound_stmt / decl_stmt hot path appends symbols at fresh
    // indices and leaves removed-subtree symbols in place with
    // use_count == 0 (append-only contract). Every oracle symbol must
    // have a matching (name, kind, use_count) symbol in `a`; any extras
    // in `a` must be dead (use_count == 0).
    var matched = try std.testing.allocator.alloc(bool, a.symbols.items.len);
    defer std.testing.allocator.free(matched);
    for (matched) |*m| m.* = false;

    for (b.symbols.items, 0..) |sb, bi| {
        const sb_uc: u32 = if (bi < b.use_counts.counts.len) b.use_counts.counts[bi] else 0;
        var found = false;
        for (a.symbols.items, 0..) |sa, i| {
            if (matched[i]) continue;
            if (sa.kind != sb.kind) continue;
            const sa_uc: u32 = if (i < a.use_counts.counts.len) a.use_counts.counts[i] else 0;
            if (sa_uc != sb_uc) continue;
            if (!std.mem.eql(u8, sa.original_name, sb.original_name)) continue;
            matched[i] = true;
            found = true;
            break;
        }
        if (!found) {
            std.debug.print(
                "oracle symbol '{s}' (kind={s}, use={d}) has no match in updated\n",
                .{ sb.original_name, @tagName(sb.kind), sb_uc },
            );
            return error.SymbolMismatch;
        }
    }
    for (a.symbols.items, matched, 0..) |sa, m, ai| {
        if (m) continue;
        const sa_uc: u32 = if (ai < a.use_counts.counts.len) a.use_counts.counts[ai] else 0;
        if (sa_uc != 0) {
            std.debug.print(
                "unmatched updated symbol '{s}' (kind={s}, use={d}) has non-zero use_count\n",
                .{ sa.original_name, @tagName(sa.kind), sa_uc },
            );
            return error.DeadSymbolHasUseCount;
        }
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

test "S4: rename at decl site takes the decl_stmt hot path" {
    // Editing the declarator name spans the let_decl. findAnchor
    // bubbles to decl_stmt (now on the hot-path allowlist), whose
    // reparse picks up the new name; module re-lower refreshes the
    // symbol table in traversal order.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; let b = a + 2; }",
        .{ .start = 13, .end = 14, .new_text = "aa" },
        "fn f() { let aa = 1; let b = a + 2; }",
        true,
    );
}

test "S5: add a new local stmt takes the compound_stmt hot path" {
    // A local-decl append lands on `compound_stmt`, which is a hot-path
    // anchor; `CstLower.lowerTree` re-derives the symbol table from the
    // spliced CST so the new `b` symbol shows up correctly.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
        "fn f() { let a = 1; let b = 2; }",
        true,
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

// =========================================================================
// A — Append-only hot path: local let/var/const additions land on the
// compound_stmt anchor and take the hot path. Each edit is verified via
// the `parseFull` oracle in `applyEditAndVerify` (shape + symbol table).
// =========================================================================

test "A1: append let into an empty body" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() {}",
        .{ .start = 8, .end = 8, .new_text = " let x = 1;" },
        "fn f() { let x = 1;}",
        true,
    );
}

test "A2: append let after last statement" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
        "fn f() { let a = 1; let b = 2; }",
        true,
    );
}

test "A3: append var with explicit type" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " var y: i32 = 0;" },
        "fn f() { let a = 1; var y: i32 = 0; }",
        true,
    );
}

test "A4: append local const" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " const C = 3;" },
        "fn f() { let a = 1; const C = 3; }",
        true,
    );
}

test "A5: append multiple statements at once" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() {}",
        .{ .start = 8, .end = 8, .new_text = " let a = 1; let b = 2; let c = 3;" },
        "fn f() { let a = 1; let b = 2; let c = 3;}",
        true,
    );
}

test "A6: append let with explicit type" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() {}",
        .{ .start = 8, .end = 8, .new_text = " let x: f32 = 1.0;" },
        "fn f() { let x: f32 = 1.0;}",
        true,
    );
}

test "A7: insert between two existing statements" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; let b = 2; }",
        .{ .start = 19, .end = 19, .new_text = " let c = 3;" },
        "fn f() { let a = 1; let c = 3; let b = 2; }",
        true,
    );
}

test "A8: prepend (insert at start of body)" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 9, .end = 9, .new_text = "let z = 0; " },
        "fn f() { let z = 0; let a = 1; }",
        true,
    );
}

test "A9: append inside a nested block" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { { let a = 1; } }",
        .{ .start = 21, .end = 21, .new_text = " let b = 2;" },
        "fn f() { { let a = 1; let b = 2; } }",
        true,
    );
}

test "A10: append inside an if branch body" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { if true { let a = 1; } }",
        .{ .start = 29, .end = 29, .new_text = " let b = 2;" },
        "fn f() { if true { let a = 1; let b = 2; } }",
        true,
    );
}

test "A11: append inside a for-loop body" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { for (var i = 0; i < 10; i = i + 1) { let t = i; } }",
        // Byte 56 sits right after `let t = i;` and before `}`.
        .{ .start = 56, .end = 56, .new_text = " let u = i + 1;" },
        "fn f() { for (var i = 0; i < 10; i = i + 1) { let t = i; let u = i + 1; } }",
        true,
    );
}

test "A12: append inside a loop continuing block" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { loop { break; continuing { let a = 1; } } }",
        .{ .start = 46, .end = 46, .new_text = " let b = 2;" },
        "fn f() { loop { break; continuing { let a = 1; let b = 2; } } }",
        true,
    );
}

test "A13: append creating a new for-loop sibling" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { for (var i = 0; i < 5; i = i + 1) {} }",
        .{ .start = 45, .end = 45, .new_text = " for (var j = 0; j < 5; j = j + 1) {}" },
        "fn f() { for (var i = 0; i < 5; i = i + 1) {} for (var j = 0; j < 5; j = j + 1) {} }",
        true,
    );
}

test "A14: append decl referencing outer symbol bumps use_count" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() { let a = 1; }";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 19,
        .end = 19,
        .new_text = " let b = a + 1;",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);

    // Oracle equivalence.
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectSymbolsMatch(updated.module, oracle.module);

    // Spot-check: find symbol `a` in updated and assert use_count > 0.
    var found_a_use: u32 = 0;
    for (updated.module.symbols.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.original_name, "a")) {
            if (i < updated.module.use_counts.counts.len) {
                found_a_use = updated.module.use_counts.counts[i];
            }
        }
    }
    try std.testing.expect(found_a_use >= 1);
}

test "A15: append inside inner block does not affect outer binding" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; { let x = 2; } }",
        .{ .start = 32, .end = 32, .new_text = " let a = 3;" },
        "fn f() { let a = 1; { let x = 2; let a = 3; } }",
        true,
    );
}

test "A16: redeclaration in same block — falls back on parser diagnostic" {
    // The parser emits E0101 when the redeclared `a` is declared in the
    // same block scope during the compound reparse, so `sub_parser.errors`
    // is non-empty and the hot path bails. The oracle still succeeds.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " let a = 2;" },
        "fn f() { let a = 1; let a = 2; }",
        false,
    );
}

test "A17: append with leading newline and indent" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() {\n    let a = 1;\n}",
        // Insert ` let b = 2;` just before the trailing newline+`}`.
        .{ .start = 23, .end = 23, .new_text = "\n    let b = 2;" },
        "fn f() {\n    let a = 1;\n    let b = 2;\n}",
        true,
    );
}

test "A18: append with interleaved line comment" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() {}",
        .{ .start = 8, .end = 8, .new_text = " // note\n    let b = 2;" },
        "fn f() { // note\n    let b = 2;}",
        true,
    );
}

test "A19: append pure whitespace — no symbol change" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = "\n " },
        "fn f() { let a = 1;\n  }",
        true,
    );
}

test "A21: unbalanced append falls back" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() { let a = 1; }";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // `let b = (` is an unclosed expression — parser emits diagnostic.
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 19,
        .end = 20,
        .new_text = " let b = (",
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);
    try std.testing.expectEqualStrings("fn f() { let a = 1; let b = (}", updated.source);
}

test "A23: edit crossing two functions falls back" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() {} fn g() {}";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // Replace bytes covering the `{}` of f through the `fn ` of g —
    // no single hot-path anchor covers the range (it straddles two
    // fn_decls), so findAnchor hits module root → fallback.
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 7,
        .end = 13,
        .new_text = " fn h() ",
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);
    try std.testing.expectEqualStrings("fn f()  fn h() g() {}", updated.source);
}

test "A24: append at module scope falls back" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() {}";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // Prepend a module-scope const. The edit sits outside fn_decl's
    // range (strictly contained only by the module root, which is not
    // a reparse anchor) → fallback.
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 0,
        .end = 0,
        .new_text = "const X = 1;\n",
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);
    try std.testing.expectEqualStrings("const X = 1;\nfn f() {}", updated.source);
    try std.testing.expectEqual(@as(usize, 2), updated.module.declarations.items.len);
}

test "A25: replace one stmt with another (same compound)" {
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 9, .end = 19, .new_text = "var a: i32 = 42;" },
        "fn f() { var a: i32 = 42; }",
        true,
    );
}

test "A26: delete last stmt falls back (anchor boundary shifts)" {
    // `findAnchor` picks the inner `decl_stmt` as the narrowest match.
    // After deletion, the first non-trivia token at the anchor's start
    // byte is past `edit.start` → `AnchorBoundaryShifted` → fallback.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; let b = 2; }",
        .{ .start = 19, .end = 30, .new_text = "" },
        "fn f() { let a = 1; }",
        false,
    );
}

test "A27: replace stmt with compound falls back on kind mismatch" {
    // Anchor is the inner `decl_stmt`; reparse yields a `compound_stmt`
    // (the new `{ … }` block), so the kind-mismatch guard bails.
    try applyEditAndVerify(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 9, .end = 19, .new_text = "{ let a = 1; let b = 2; }" },
        "fn f() { { let a = 1; let b = 2; } }",
        false,
    );
}

test "A29: downstream decl offsets shift after a body append" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() { }\nconst x = 1;";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // Append a local into f's body.
    var r1 = try Incremental.reparse(gpa, &prev, .{
        .start = 9,
        .end = 9,
        .new_text = "let y = 2;",
    });
    defer r1.deinit();
    try std.testing.expect(r1.reused);
    try std.testing.expectEqualStrings("fn f() { let y = 2;}\nconst x = 1;", r1.source);

    // Now edit the literal `1` inside `const x = 1;`. It's at byte 31
    // in the shifted source.
    const one_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, r1.source, '1').?);
    var r2 = try Incremental.reparse(gpa, &r1, .{
        .start = one_off,
        .end = one_off + 1,
        .new_text = "99",
    });
    defer r2.deinit();
    try std.testing.expect(r2.reused);
    try std.testing.expectEqualStrings("fn f() { let y = 2;}\nconst x = 99;", r2.source);
}

test "A31: 50 successive appends all take the hot path" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() {}";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        // Byte offset of `}` is always source.len - 1.
        const close_off: u32 = @intCast(cur.source.len - 1);
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, " let v{} = {};", .{ i, i });
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = close_off,
            .end = close_off,
            .new_text = payload,
        });
        cur.deinit();
        cur = next;
        try std.testing.expect(cur.reused);
    }
    try std.testing.expectEqual(@as(usize, 1), cur.module.declarations.items.len);

    // Shape/symbol equivalence with a fresh full parse.
    var oracle = try Incremental.parseFull(gpa, cur.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, cur.module, oracle.module);
    try expectSymbolsMatch(cur.module, oracle.module);
}

test "A32: alternating appends across two function bodies" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() {}\nfn g() {}";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const target: []const u8 = if (i % 2 == 0) "fn f()" else "fn g()";
        const f_start = std.mem.indexOf(u8, cur.source, target).?;
        // Find the `{` after `fn X()`.
        const brace_open = std.mem.indexOfScalarPos(u8, cur.source, f_start, '{').?;
        const brace_close = std.mem.indexOfScalarPos(u8, cur.source, brace_open, '}').?;
        const close_off: u32 = @intCast(brace_close);
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, " let v{} = {};", .{ i, i });
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = close_off,
            .end = close_off,
            .new_text = payload,
        });
        cur.deinit();
        cur = next;
        try std.testing.expect(cur.reused);
    }
    try std.testing.expectEqual(@as(usize, 2), cur.module.declarations.items.len);
}

// =========================================================================
// SS-series: sentinel-stub-sharing scenarios
//
// These tests mirror the four hot-path categories (trivia-only,
// symbol-free add/sub, compound_stmt, decl_stmt) that now share the
// module-scope `Incremental.sentinel_stub`. Every scenario verifies the
// three invariants in one go:
//
//   1. Edit result matches a full re-parse (shape + symbols) — reused
//      by `applyEditAndVerify`.
//   2. After the reparse, the *old* `prev.arena` equals
//      `&Incremental.sentinel_stub` (hot-path transfer).
//   3. `Incremental.sentinel_stub.queryCapacity()` stays 0 — no bytes
//      accidentally allocated into the shared sentinel.
//
// `applySingleEditAndAssertSentinel` is the per-test helper; bursts use
// a local loop and assert the sentinel invariants on every step.
// =========================================================================

fn applySingleEditAndAssertSentinel(
    gpa: std.mem.Allocator,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
    expected_src: []const u8,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    // Sentinel capacity must be 0 before the hot path runs — it's
    // pre-declared empty and nothing should ever allocate into it.
    try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());

    const captured_base_arena = base.arena;
    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings(expected_src, updated.source);

    // Hot-path transfer: updated inherits base's original real arena;
    // base now holds the sentinel.
    try std.testing.expectEqual(captured_base_arena, updated.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, base.arena);
    try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());

    var oracle = try Incremental.parseFull(gpa, expected_src);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectSymbolsMatch(updated.module, oracle.module);
}

// -------------------------------------------------------------------------
// SS-T: trivia-only path (`tryTriviaOnlyShortcut`)
//
// Zero-delta (same length new_text) edits confined to whitespace or
// comment content never alter non-trivia tokens, so the shortcut
// returns with the sentinel installed and the cached analysis hot.
// -------------------------------------------------------------------------

test "SS-T1: comment-body rewrite, same length" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "// old_tag\nconst X = 1;",
        .{ .start = 3, .end = 10, .new_text = "new_tag" },
        "// new_tag\nconst X = 1;",
    );
}

test "SS-T2: block comment body rewrite, same length" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "/* aaa */ const X = 1;",
        .{ .start = 3, .end = 6, .new_text = "bbb" },
        "/* bbb */ const X = 1;",
    );
}

test "SS-T3: whitespace swap (two spaces to two tabs)" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "const X =  1;",
        .{ .start = 9, .end = 11, .new_text = "\t\t" },
        "const X =\t\t1;",
    );
}

test "SS-T4: single-char replacement inside a line comment" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "// abc\nconst X = 1;",
        .{ .start = 5, .end = 6, .new_text = "d" },
        "// abd\nconst X = 1;",
    );
}

test "SS-T5: trivia-only burst of 50 comment rewrites" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "// tag_00\nconst X = 1;";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 1;
    while (i <= 50) : (i += 1) {
        // Rewrite the 2-digit number inside `tag_NN` with a new 2-digit
        // number. Zero-delta every iteration.
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "tag_").? + "tag_".len);
        var buf: [2]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "{d:0>2}", .{i % 100});
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = off,
            .end = off + 2,
            .new_text = &buf,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }
}

// -------------------------------------------------------------------------
// SS-A: symbol-free add/sub path (`tryAddSubSpliceInPlace`)
//
// Edits inside expression anchors — literal/operator/ident/call/index/
// member/unary — never introduce or destroy symbols. The driver reuses
// prev.arena, runs sub/add walks over the replaced subtree, and hands
// the sentinel back on prev.
// -------------------------------------------------------------------------

test "SS-A1: literal bump inside return expression" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() -> f32 { return 3.14; }",
        .{ .start = 23, .end = 27, .new_text = "3.15" },
        "fn f() -> f32 { return 3.15; }",
    );
}

test "SS-A2: binary operator flip (+ → *)" {
    const src: [:0]const u8 = "const x = 1; const y = 2; fn f() { var z = 0; z = x + y; }";
    const plus_off: u32 = @intCast(std.mem.indexOfPos(u8, src, 50, "+").?);
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        src,
        .{ .start = plus_off, .end = plus_off + 1, .new_text = "*" },
        "const x = 1; const y = 2; fn f() { var z = 0; z = x * y; }",
    );
}

test "SS-A3: identifier swap at a use site" {
    // `let a = 1; let b = 2;` are both in scope; swap `a` in `return a;`
    // to `b` — pure symbol-free ident_expr rewrite.
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() -> i32 { let a = 1; let b = 2; return a; }",
        .{ .start = 45, .end = 46, .new_text = "b" },
        "fn f() -> i32 { let a = 1; let b = 2; return b; }",
    );
}

test "SS-A4: call argument literal swap" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn g(a: i32, b: i32) -> i32 { return a + b; } fn f() -> i32 { return g(1, 2); }",
        // Replace the `2` in the call.
        .{ .start = 74, .end = 75, .new_text = "5" },
        "fn g(a: i32, b: i32) -> i32 { return a + b; } fn f() -> i32 { return g(1, 5); }",
    );
}

test "SS-A5: unary negation operand swap (-x → -y)" {
    // WGSL has no unary `+`, so we exercise the unary_expr path by
    // swapping its operand identifier instead.
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() -> i32 { let x = 1; let y = 2; return -x; }",
        .{ .start = 46, .end = 47, .new_text = "y" },
        "fn f() -> i32 { let x = 1; let y = 2; return -y; }",
    );
}

test "SS-A6: 50-edit literal burst on the same return expression" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() -> i32 { return 0; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 0;
    var hot_count: u32 = 0;
    while (i < 50) : (i += 1) {
        // Flip between single-digit literals.
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "return ").?);
        const digit_off: u32 = off + @as(u32, @intCast("return ".len));
        var buf: [1]u8 = .{@as(u8, '0') + @as(u8, @intCast(i % 10))};
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = digit_off,
            .end = digit_off + 1,
            .new_text = &buf,
        });
        if (next.reused) {
            hot_count += 1;
            try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        } else {
            try std.testing.expect(cur.arena != &Incremental.sentinel_stub);
        }
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }
    // 50 edits on a tiny source stay well below both the edit-count
    // (256) and the byte-watermark (256 KiB) coalesce thresholds.
    try std.testing.expect(hot_count >= 45);
}

// -------------------------------------------------------------------------
// SS-C: compound_stmt path (`tryCompoundSpliceInPlace`)
//
// Adding / removing / reordering statements inside a function body.
// The driver re-lowers the compound, patches the symbol table (append-
// only), and hands the sentinel back.
// -------------------------------------------------------------------------

test "SS-C1: append a new statement at the end of a function body" {
    // Insert immediately before the closing `}` (index 20). The source
    // already has a trailing space at index 19, so the new_text starts
    // with a plain `let` and ends with `; ` to preserve formatting.
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 20, .end = 20, .new_text = "let b = 2; " },
        "fn f() { let a = 1; let b = 2; }",
    );
}

test "SS-C2: insert a statement in the middle of a function body" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let a = 1; let c = 3; }",
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
        "fn f() { let a = 1; let b = 2; let c = 3; }",
    );
}

test "SS-C3: insert a statement between two existing ones" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let a = 1; let c = 3; }",
        // Insert ` let b = 2;` right after the `;` of `let a = 1;`.
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
        "fn f() { let a = 1; let b = 2; let c = 3; }",
    );
}

test "SS-C4: 20 appends in a row to the same function body" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() {}";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 0;
    var hot_count: u32 = 0;
    while (i < 20) : (i += 1) {
        const close_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, cur.source, '}').?);
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, " let v{d} = {d};", .{ i, i });
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = close_off,
            .end = close_off,
            .new_text = payload,
        });
        if (next.reused) {
            hot_count += 1;
            try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        } else {
            try std.testing.expect(cur.arena != &Incremental.sentinel_stub);
        }
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }
    try std.testing.expect(hot_count >= 18);
}

// -------------------------------------------------------------------------
// SS-D: decl_stmt path (`tryDeclStmtSpliceInPlace`)
//
// Edits confined to a single declaration statement inside a function
// body — even ones that mutate the symbol table (rename the LHS
// identifier) — still transfer the sentinel onto prev.
// -------------------------------------------------------------------------

test "SS-D1: let initializer literal swap" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let x = 1; }",
        .{ .start = 17, .end = 18, .new_text = "9" },
        "fn f() { let x = 9; }",
    );
}

test "SS-D2: let with explicit type annotation, literal swap" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let x: f32 = 1.0; }",
        .{ .start = 22, .end = 25, .new_text = "2.5" },
        "fn f() { let x: f32 = 2.5; }",
    );
}

test "SS-D3: var initializer literal swap" {
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { var y = 0; }",
        .{ .start = 17, .end = 18, .new_text = "9" },
        "fn f() { var y = 9; }",
    );
}

test "SS-D4: rename the LHS identifier of a let binding" {
    // Renaming the LHS mutates the symbol table. The decl_stmt path
    // handles it by appending a new symbol and marking the old one
    // removed; sentinel identity and emptiness still hold.
    try applySingleEditAndAssertSentinel(
        std.testing.allocator,
        "fn f() { let x = 1; }",
        .{ .start = 13, .end = 14, .new_text = "z" },
        "fn f() { let z = 1; }",
    );
}

// =========================================================================
// Interior-bias drain (absorbInteriors) after a byte-deleting hot edit.
//
// Regression: `Parameter.span` / `StructMember.span` were dead-on-read but
// still written by the interior-bias shift walk (`shiftDeclInteriorPart`).
// On the Parser AST path (the only path since Block 1.3) they are always
// `.empty` == (0,0); a byte-DELETING edit gives a downstream struct or
// param'd function a negative `interior_pending`, and draining that bias via
// `absorbInteriors` shifted the empty (0,0) span to -1 → `@intCast` panic.
// Every external span reader (Validator, LSP, Printer) calls
// `absorbInteriors` at entry, so this was a live LSP crash. Deleting the two
// dead fields removes them from the shift walk and fixes it.
// =========================================================================

test "R1: absorbInteriors after a delete upstream of a struct does not underflow" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 =
        "const x = 1;\nfn f() { let y = x + 2; return; }\nstruct S { a: f32, b: vec3<f32> }\n";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();
    // Delete the space in "fn f() {" → the downstream struct gets bias -1.
    var updated = try Incremental.reparse(gpa, &prev, .{ .start = 19, .end = 20, .new_text = "" });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    // Must not panic, and must leave every span in current coordinates.
    updated.module.absorbInteriors();
    const s = updated.module.declarations.items[2].@"struct";
    const t = s.members.items[0].typ.span();
    try std.testing.expectEqualStrings("f32", updated.source[t.start..t.end]);
}

test "R2: absorbInteriors after a delete upstream of a param'd fn does not underflow" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 =
        "fn a() { let z = 1; }\nfn g(p: f32) -> f32 { return p; }\n";
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();
    // Delete the space in "fn a() {" → the downstream param'd fn gets bias -1.
    var updated = try Incremental.reparse(gpa, &prev, .{ .start = 6, .end = 7, .new_text = "" });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    updated.module.absorbInteriors();
    const g = updated.module.declarations.items[1].function;
    const t = g.parameters.items[0].typ.span();
    try std.testing.expectEqualStrings("f32", updated.source[t.start..t.end]);
}

// =========================================================================
// B3b — strong-oracle gate for the scope-bearing hot paths.
//
// The SS-C / SS-D / A-series tests above gate the compound_stmt and
// decl_stmt splice paths with the *weak* oracle (`expectSymbolsMatch`:
// symbol name/kind/use_count + decl-tag shape). That oracle is blind to
// the scope tree — kind, `sibling_index`, member refs, child structure.
//
// These tests gate the same two paths with `ast_equal.expectModulesEquivalent`
// (the stale-tolerant structural oracle the fuzz test uses): full
// decl/stmt/expr/type trees with byte-identical spans + flags, and the
// scope tree including `sibling_index`. This is the safety net that keeps
// the Block-1.4 CstLower→Parser anchor swap behavior-preserving — a
// spliced module whose scope structure or spans drift from a fresh parse
// fails here where the weak oracle would wave it through.
// =========================================================================

fn applyEditAndVerifyStrong(
    gpa: std.mem.Allocator,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
    expected_src: []const u8,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected_src, updated.source);
    try std.testing.expect(updated.reused);

    var oracle = try Incremental.parseFull(gpa, expected_src);
    defer oracle.deinit();

    // Drain lazy interior-bias on both before the structural compare — every
    // external span reader does this at entry, and the oracle compare is one.
    updated.module.absorbInteriors();
    oracle.module.absorbInteriors();

    try ast_equal.expectModulesEquivalent(gpa, oracle.module, updated.module);
}

test "B3b-D1: decl anchor — rename LHS, strong structural oracle" {
    try applyEditAndVerifyStrong(
        std.testing.allocator,
        "fn f() { let x = 1; let y = x + 2; }",
        .{ .start = 13, .end = 14, .new_text = "w" },
        "fn f() { let w = 1; let y = x + 2; }",
    );
}
