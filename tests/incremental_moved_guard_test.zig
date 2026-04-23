//! Unit tests for the `ReparseResult.moved` move-semantics guard.
//!
//! Every successful `Incremental.reparse` transfers ownership of
//! `prev.arena`, `prev.module`, `prev.cst`, `prev.source`,
//! `prev.scope_for_cst_node`, and `prev.errors` to the returned
//! result. The `moved` flag pins this contract: after a hot-path
//! return, `prev.moved == true`; after a fallback `parseFull`,
//! `prev.moved == false` (prev is untouched). A second `reparse` on
//! a moved-from prev returns `error.PrevAlreadyMoved`.
//!
//! These tests lock in:
//!   1. Every hot path sets `moved = true` (MG1–MG4).
//!   2. Every fallback leaves `moved = false` (MG5–MG8).
//!   3. Fresh results default to `moved = false` (MG9–MG10).
//!   4. Double-reparse on a moved prev is a typed error (MG11–MG12).
//!   5. Moved prev remains deinit-safe (MG13).
//!   6. `moved` is paired with `arena == &sentinel_stub` (MG14).
//!   7. Chained reparse preserves the invariants across bursts (MG15).
//!   8. The LSP handler's existing (reparse → deinit prev → use
//!      updated) pattern keeps working (MG16).
//!   9. Fallback after a prior move leaves the new prev unmoved (MG17).
//!  10. `arenaBytes` / `scopeAtCstNode` work on live results (MG18).
//!  11. Property across a 100-edit burst:
//!      `prev.moved == updated.reused` (MG19).

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;
const Cst = wgslender.Cst;

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

/// Parse `base`, apply `edit`, verify that the hot path fired and
/// `prev.moved == true` with the paired sentinel invariants.
fn expectMovedAfterHotPath(
    gpa: std.mem.Allocator,
    base: [:0]const u8,
    edit: Incremental.Edit,
) !void {
    var prev = try Incremental.parseFull(gpa, base);
    try std.testing.expect(!prev.moved);
    const captured_arena = prev.arena;

    var updated = try Incremental.reparse(gpa, &prev, edit);
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expect(prev.moved);
    try std.testing.expect(!updated.moved);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    try std.testing.expectEqual(captured_arena, updated.arena);
    prev.deinit();
}

/// Parse `base`, apply `edit`, verify that the fallback fired and
/// `prev.moved` is still false with arena unchanged.
fn expectUnmovedAfterFallback(
    gpa: std.mem.Allocator,
    base: [:0]const u8,
    edit: Incremental.Edit,
) !void {
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();
    const captured_arena = prev.arena;

    var updated = try Incremental.reparse(gpa, &prev, edit);
    defer updated.deinit();

    try std.testing.expect(!updated.reused);
    try std.testing.expect(!prev.moved);
    try std.testing.expect(!updated.moved);
    try std.testing.expectEqual(captured_arena, prev.arena);
    try std.testing.expect(updated.arena != &Incremental.sentinel_stub);
    try std.testing.expect(prev.arena != &Incremental.sentinel_stub);
}

// ---------------------------------------------------------------------------
// MG1–MG4 — every hot path sets `prev.moved = true`.
// ---------------------------------------------------------------------------

test "MG1: trivia-only shortcut sets prev.moved = true" {
    // Same-length comment body rewrite routes through
    // `tryTriviaOnlyShortcut` → sentinel + moved = true.
    try expectMovedAfterHotPath(
        std.testing.allocator,
        "// aaa\nconst X = 1;",
        .{ .start = 3, .end = 6, .new_text = "bbb" },
    );
}

test "MG2: symbol-free add/sub path sets prev.moved = true" {
    // Literal bump inside a return — anchor is literal_expr, routes
    // through `tryAddSubSpliceInPlace`.
    try expectMovedAfterHotPath(
        std.testing.allocator,
        "fn f() -> i32 { return 1; }",
        .{ .start = 23, .end = 24, .new_text = "2" },
    );
}

test "MG3: compound_stmt path sets prev.moved = true" {
    // Append a new local decl immediately before the closing `}` →
    // `tryCompoundSpliceInPlace`.
    try expectMovedAfterHotPath(
        std.testing.allocator,
        "fn f() { let a = 1; }",
        .{ .start = 19, .end = 19, .new_text = " let b = 2;" },
    );
}

test "MG4: decl_stmt path sets prev.moved = true" {
    // Rename the LHS identifier of a `let` — routes through
    // `tryDeclStmtSpliceInPlace`.
    try expectMovedAfterHotPath(
        std.testing.allocator,
        "fn f() { let x = 1; }",
        .{ .start = 13, .end = 14, .new_text = "z" },
    );
}

// ---------------------------------------------------------------------------
// MG5–MG8 — fallback paths leave prev untouched.
// ---------------------------------------------------------------------------

test "MG5: no-anchor fallback leaves prev.moved = false" {
    // Inserting a whole new top-level decl at offset 0 has no single
    // anchor — falls back to parseFull.
    try expectUnmovedAfterFallback(
        std.testing.allocator,
        "const X = 1;",
        .{ .start = 0, .end = 0, .new_text = "const Y = 2; " },
    );
}

test "MG6: anchor-kind-mismatch fallback leaves prev.moved = false" {
    // Editing "1" into "1 * 3" inside "return 1 + 2;" — the anchor is
    // a literal_expr that becomes a binary_expr on re-parse. Kind
    // mismatch → fallback.
    try expectUnmovedAfterFallback(
        std.testing.allocator,
        "fn f() -> i32 { return 1 + 2; }",
        .{ .start = 23, .end = 24, .new_text = "1 * 3" },
    );
}

test "MG7: edit that spans two decls falls back, prev.moved = false" {
    // Range-delete that crosses the `;` boundary between two decls
    // cannot be re-parsed as a single anchor — fallback.
    try expectUnmovedAfterFallback(
        std.testing.allocator,
        "const A = 1; const B = 2;",
        .{ .start = 10, .end = 15, .new_text = "99 const" },
    );
}

test "MG8: isEmpty no-op edit leaves prev.moved = false" {
    // The no-op branch in `reparseImpl` forwards to `parseFull` and
    // never mutates prev. prev.moved stays false; updated is fresh.
    const gpa = std.testing.allocator;
    var prev = try Incremental.parseFull(gpa, "fn f() { }");
    defer prev.deinit();

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 5,
        .end = 5,
        .new_text = "",
    });
    defer updated.deinit();

    try std.testing.expect(!updated.reused);
    try std.testing.expect(!prev.moved);
    try std.testing.expect(!updated.moved);
}

// ---------------------------------------------------------------------------
// MG9–MG10 — fresh results default to `moved == false`.
// ---------------------------------------------------------------------------

test "MG9: parseFull returns moved = false" {
    const gpa = std.testing.allocator;
    var r = try Incremental.parseFull(gpa, "const X = 1;");
    defer r.deinit();
    try std.testing.expect(!r.moved);
}

test "MG10: successful hot-path updated returns moved = false" {
    const gpa = std.testing.allocator;
    var prev = try Incremental.parseFull(gpa, "fn f() -> i32 { return 1; }");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 23,
        .end = 24,
        .new_text = "7",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expect(!updated.moved);
    try std.testing.expect(prev.moved);
    prev.deinit();
}

// ---------------------------------------------------------------------------
// MG11–MG12 — double-move rejected.
// ---------------------------------------------------------------------------

test "MG11: reparse on moved prev returns error.PrevAlreadyMoved" {
    const gpa = std.testing.allocator;
    var prev = try Incremental.parseFull(gpa, "fn f() -> i32 { return 1; }");

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 23,
        .end = 24,
        .new_text = "2",
    });
    defer updated.deinit();
    try std.testing.expect(prev.moved);

    // Second reparse on the already-moved prev must be a typed error.
    // The first `updated` and the sentinel state of prev are untouched.
    const err = Incremental.reparse(gpa, &prev, .{
        .start = 23,
        .end = 24,
        .new_text = "3",
    });
    try std.testing.expectError(error.PrevAlreadyMoved, err);
    try std.testing.expect(prev.moved);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    prev.deinit();
}

test "MG12: chained reparse — each immediate prev is moved, new ones are not" {
    const gpa = std.testing.allocator;
    var r1 = try Incremental.parseFull(gpa, "fn f() -> i32 { return 0; }");

    var r2 = try Incremental.reparse(gpa, &r1, .{
        .start = 23,
        .end = 24,
        .new_text = "1",
    });
    try std.testing.expect(r1.moved);
    try std.testing.expect(!r2.moved);
    r1.deinit();

    var r3 = try Incremental.reparse(gpa, &r2, .{
        .start = 23,
        .end = 24,
        .new_text = "2",
    });
    defer r3.deinit();
    try std.testing.expect(r2.moved);
    try std.testing.expect(!r3.moved);
    r2.deinit();
}

// ---------------------------------------------------------------------------
// MG13 — moved prev still deinits safely.
// ---------------------------------------------------------------------------

test "MG13: moved prev.deinit() is a no-op under testing.allocator" {
    // testing.allocator traps any destroy of non-gpa-owned memory.
    // The sentinel guard in `ReparseResult.deinit` is what makes this
    // safe. Exercise it from all four hot paths to ensure every site
    // plays nicely with the allocator.
    const gpa = std.testing.allocator;

    inline for (.{
        .{ "// xyz\nconst X = 1;", Incremental.Edit{ .start = 3, .end = 6, .new_text = "ZZZ" } },
        .{ "fn f() -> i32 { return 1; }", Incremental.Edit{ .start = 23, .end = 24, .new_text = "2" } },
        .{ "fn f() { let a = 1; }", Incremental.Edit{ .start = 19, .end = 19, .new_text = " let b = 2;" } },
        .{ "fn f() { let x = 1; }", Incremental.Edit{ .start = 13, .end = 14, .new_text = "y" } },
    }) |case| {
        var prev = try Incremental.parseFull(gpa, case[0]);
        var updated = try Incremental.reparse(gpa, &prev, case[1]);
        defer updated.deinit();
        try std.testing.expect(updated.reused);
        try std.testing.expect(prev.moved);
        prev.deinit(); // sentinel-guard short-circuit; allocator sees no destroy.
    }
}

// ---------------------------------------------------------------------------
// MG14 — `moved` is paired with `arena == &sentinel_stub`.
// ---------------------------------------------------------------------------

test "MG14: moved and sentinel are tightly coupled on every hot path" {
    const gpa = std.testing.allocator;

    inline for (.{
        .{ "// xyz\nconst X = 1;", Incremental.Edit{ .start = 3, .end = 6, .new_text = "ZZZ" } },
        .{ "fn f() -> i32 { return 1; }", Incremental.Edit{ .start = 23, .end = 24, .new_text = "2" } },
        .{ "fn f() { let a = 1; }", Incremental.Edit{ .start = 19, .end = 19, .new_text = " let b = 2;" } },
        .{ "fn f() { let x = 1; }", Incremental.Edit{ .start = 13, .end = 14, .new_text = "y" } },
    }) |case| {
        var prev = try Incremental.parseFull(gpa, case[0]);
        var updated = try Incremental.reparse(gpa, &prev, case[1]);
        defer updated.deinit();
        try std.testing.expect(updated.reused);
        // Conjunction: both flags flip together. If either site ever
        // sets one without the other, this test trips.
        try std.testing.expect(prev.moved and prev.arena == &Incremental.sentinel_stub);
        prev.deinit();
    }
}

// ---------------------------------------------------------------------------
// MG15 — chained burst walks the moved flag correctly.
// ---------------------------------------------------------------------------

test "MG15: 20-edit chained burst — immediate prev is moved, current is not" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() -> i32 { return 0; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();
    try std.testing.expect(!cur.moved);

    const literal_start: u32 = 23;
    var literal_len: u32 = 1;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = literal_start + literal_len,
            .end = literal_start + literal_len,
            .new_text = "0",
        });
        try std.testing.expect(next.reused);
        try std.testing.expect(cur.moved);
        try std.testing.expect(!next.moved);
        cur.deinit();
        cur = next;
        literal_len += 1;
    }
    // Final `cur` is the last unmoved result.
    try std.testing.expect(!cur.moved);
}

// ---------------------------------------------------------------------------
// MG16 — LSP-handler (reparse → deinit prev → use updated) pattern.
// ---------------------------------------------------------------------------

test "MG16: LSP-handler pattern does not trip the moved guard" {
    // Mirrors `lsp/Handler.zig:updateParseAfterEdit` at line 2715.
    // The key sequence: reparse, then deinit prev, then the caller
    // goes on to use `updated` (here: read a field + defer deinit).
    const gpa = std.testing.allocator;
    var prev = try Incremental.parseFull(gpa, "fn f() -> i32 { return 1; }");

    const updated = try Incremental.reparse(gpa, &prev, .{
        .start = 23,
        .end = 24,
        .new_text = "9",
    });
    prev.deinit(); // prev.moved == true here — deinit must still work.

    var mut_updated = updated;
    defer mut_updated.deinit();
    try std.testing.expect(mut_updated.reused);
    try std.testing.expect(!mut_updated.moved);
    try std.testing.expectEqualStrings("fn f() -> i32 { return 9; }", mut_updated.source);
}

// ---------------------------------------------------------------------------
// MG17 — fallback after a prior hot-path move leaves the new prev unmoved.
// ---------------------------------------------------------------------------

test "MG17: fallback after a prior move leaves next prev.moved = false" {
    const gpa = std.testing.allocator;
    var r1 = try Incremental.parseFull(gpa, "fn f() -> i32 { return 1; }");

    var r2 = try Incremental.reparse(gpa, &r1, .{
        .start = 23,
        .end = 24,
        .new_text = "7",
    });
    try std.testing.expect(r1.moved);
    try std.testing.expect(!r2.moved);
    r1.deinit();

    // Force a fallback on r2: edit range crosses the top-level decl
    // boundary so no single anchor applies.
    var r3 = try Incremental.reparse(gpa, &r2, .{
        .start = 0,
        .end = 0,
        .new_text = "const X = 1; ",
    });
    defer r3.deinit();
    try std.testing.expect(!r3.reused);
    // r2 is the fallback's prev — untouched → moved stays false.
    try std.testing.expect(!r2.moved);
    try std.testing.expect(!r3.moved);
    r2.deinit();
}

// ---------------------------------------------------------------------------
// MG18 — `arenaBytes` / `scopeAtCstNode` work on live results after a chain.
// ---------------------------------------------------------------------------

test "MG18: arenaBytes and scopeAtCstNode succeed on live results" {
    // Positive-coverage counterpart of the debug asserts in
    // `arenaBytes` / `scopeAtCstNode`. After several hot-path edits
    // the `updated` result is live (not moved), and both helpers
    // return a sensible value without tripping an assert.
    const gpa = std.testing.allocator;
    var cur = try Incremental.parseFull(gpa, "fn f() -> i32 { return 0; }");
    defer cur.deinit();

    const literal_start: u32 = 23;
    var literal_len: u32 = 1;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = literal_start + literal_len,
            .end = literal_start + literal_len,
            .new_text = "0",
        });
        cur.deinit();
        cur = next;
        literal_len += 1;
    }

    try std.testing.expect(cur.arenaBytes() > 0);
    // `.root` is the module node; `scopeAtCstNode` walks up to the
    // module scope and returns it.
    const scope = Incremental.scopeAtCstNode(&cur, .root);
    try std.testing.expectEqual(cur.module.scope, scope);
}

// ---------------------------------------------------------------------------
// MG19 — property: (prev.moved == true) iff (updated.reused == true).
// ---------------------------------------------------------------------------

test "MG19: property — prev.moved mirrors updated.reused across 100 edits" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() -> i32 { return 0; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "return ").?);
        const digit_off: u32 = off + @as(u32, @intCast("return ".len));
        const replacement: []const u8 = if (i % 2 == 0) "1" else "0";
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = digit_off,
            .end = digit_off + 1,
            .new_text = replacement,
        });
        // Property: a hot-path return (`reused == true`) must always
        // coincide with `prev.moved == true`; a fallback return
        // (`reused == false`) must always coincide with
        // `prev.moved == false`.
        try std.testing.expectEqual(next.reused, cur.moved);
        try std.testing.expect(!next.moved);
        cur.deinit();
        cur = next;
    }
}
