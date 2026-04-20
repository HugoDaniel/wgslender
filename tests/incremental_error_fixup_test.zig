//! End-to-end tests for the parse-error fixup applied across an
//! incremental reparse splice.
//!
//! Every scenario validates `updated.errors` against an oracle produced
//! by `Incremental.parseFull(updated.source)` — so by construction the
//! splice machinery has to match what a fresh parse would have produced.
//!
//! Note on E0102. The sole error code emitted by Pass-2 (visit) is
//! E0102, "<name> is used before its declaration". It only fires when
//! the symbol exists somewhere in the function's scope chain but is
//! declared after the use. Truly-undefined identifiers don't generate
//! a Pass-2 error — `Validator` reports them separately. So every
//! E0102-bearing scenario here uses a same-named local declared
//! further down the function body to manufacture a use-before-decl.
//!
//! Test families:
//!   F-DROP    — entries strictly inside the old anchor are dropped.
//!   F-SHIFT   — entries strictly after the old anchor shift by delta.
//!   F-LEAVE   — entries before the old anchor are untouched.
//!   F-NEW     — add-walk emits new errors with new-source positions
//!               and the hot path stays engaged (no AddWalkRaisedErrors
//!               fallback).
//!   F-MIX     — drop + shift + new in a single edit.
//!   F-ROUND   — round-trip stability across edit + inverse and bursts.
//!   F-TRIVIA  — trivia-only shortcut preserves error positions.
//!   F-FALLBACK — non-symbol-free anchors keep error semantics on the
//!                full re-lower path.
//!   F-KIND    — every error code survives the fixup.

const std = @import("std");
const wgslender = @import("wgslender");

const Allocator = std.mem.Allocator;
const Incremental = wgslender.Incremental;
const Parser = wgslender.Parser;

// =========================================================================
// Harness
// =========================================================================

/// Position-and-code equality. Message strings are allowed to vary
/// (E0102 includes the ident name, which renames change), so we compare
/// only the load-bearing fields the hot path is responsible for keeping
/// stable: `code`, `pos`, `end`. Length equality + per-entry comparison
/// proves every drop / shift / append decision matched the oracle.
fn expectErrorsMatch(got: []const Parser.ParseError, oracle: []const Parser.ParseError) !void {
    if (got.len != oracle.len) {
        std.debug.print("error count mismatch: got={d} oracle={d}\n", .{ got.len, oracle.len });
        for (got) |g| std.debug.print("  got    {s} pos={d} end={d}: {s}\n", .{ g.code, g.pos, g.end, g.message });
        for (oracle) |o| std.debug.print("  oracle {s} pos={d} end={d}: {s}\n", .{ o.code, o.pos, o.end, o.message });
        return error.ErrorCountMismatch;
    }
    for (got, oracle) |g, o| {
        try std.testing.expectEqualStrings(o.code, g.code);
        try std.testing.expectEqual(o.pos, g.pos);
        try std.testing.expectEqual(o.end, g.end);
    }
}

fn runEditWithErrors(
    gpa: Allocator,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
    expected_new_src: []const u8,
    expect_reused: bool,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected_new_src, updated.source);
    try std.testing.expectEqual(expect_reused, updated.reused);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectErrorsMatch(updated.errors, oracle.errors);
}

fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

// =========================================================================
// F-DROP — entries strictly inside the old anchor are dropped.
//
// Each base has a use-before-decl E0102 INSIDE the anchor. The edit
// replaces the anchor with a clean expression, so the old E0102 must be
// dropped (and no new one emitted).
// =========================================================================

test "F-DROP-01: edit replacing a use-before-decl ident drops its E0102" {
    // Base: `q` in the early return is use-before-decl (later `let q`).
    const src: [:0]const u8 =
        "fn f() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return q;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return q;".len), .new_text = "return 0;" },
        "fn f() -> i32 { return 0; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-DROP-02: edit on a binary containing a use-before-decl drops the E0102" {
    const src: [:0]const u8 =
        "fn f(a: i32) -> i32 { return a + bad + a; let bad: i32 = 1; return bad; }";
    const start: u32 = at(src, "return a + bad + a;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return a + bad + a;".len),
            .new_text = "return 0;",
        },
        "fn f(a: i32) -> i32 { return 0; let bad: i32 = 1; return bad; }",
        true,
    );
}

test "F-DROP-03: edit on a call to a use-before-decl drops the E0102" {
    // The `helper` ident in the early return is use-before-decl.
    const src: [:0]const u8 =
        "fn f() -> i32 { return helper; let helper: i32 = 1; return helper; }";
    const start: u32 = at(src, "return helper;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return helper;".len),
            .new_text = "return 42;",
        },
        "fn f() -> i32 { return 42; let helper: i32 = 1; return helper; }",
        true,
    );
}

// =========================================================================
// F-SHIFT — entries strictly after the old anchor shift by delta.
//
// `g`'s body has a use-before-decl E0102. The edit lands earlier in the
// file, so the E0102's pos must shift by exactly `delta`.
// =========================================================================

test "F-SHIFT-01: positive delta shifts a downstream E0102 by exactly delta" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return 1;".len),
            .new_text = "return 1+1+1+1;",
        },
        "fn f() -> i32 { return 1+1+1+1; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-SHIFT-02: zero-delta literal swap leaves a downstream E0102 in place" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = "return 0;" },
        "fn f() -> i32 { return 0; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-SHIFT-03: large positive delta keeps a downstream E0102 correct" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 1;");
    const big = "return 0+1+2+3+4+5+6+7+8+9+10+11+12+13+14+15+16+17+18+19+20+21+22+23+24+25+26+27+28+29+30+31+32+33+34+35+36+37+38+39+40+41+42+43+44+45+46+47+48+49+50+51+52+53+54+55+56+57;";
    const new_src = try std.fmt.allocPrint(
        std.testing.allocator,
        "fn f() -> i32 {{ {s} }} fn g() -> i32 {{ return q; let q: i32 = 1; return q; }}",
        .{big},
    );
    defer std.testing.allocator.free(new_src);
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = big },
        new_src,
        true,
    );
}

test "F-SHIFT-04: pure deletion shifts downstream errors by -N" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1+2+3+4+5; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 1+2+3+4+5;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return 1+2+3+4+5;".len),
            .new_text = "return 0;",
        },
        "fn f() -> i32 { return 0; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

// =========================================================================
// F-LEAVE — entries before the old anchor are untouched.
// =========================================================================

test "F-LEAVE-01: edit downstream leaves an upstream E0102 unchanged" {
    const src: [:0]const u8 =
        "fn g() -> i32 { return q; let q: i32 = 1; return q; } fn f() -> i32 { return 1; }";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = "return 9;" },
        "fn g() -> i32 { return q; let q: i32 = 1; return q; } fn f() -> i32 { return 9; }",
        true,
    );
}

test "F-LEAVE-02: two upstream errors all kept when edit lands later" {
    const src: [:0]const u8 =
        "fn g() -> i32 { return q + r; let q: i32 = 1; let r: i32 = 2; return q + r; } fn f() -> i32 { return 1; }";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = "return 7;" },
        "fn g() -> i32 { return q + r; let q: i32 = 1; let r: i32 = 2; return q + r; } fn f() -> i32 { return 7; }",
        true,
    );
}

// =========================================================================
// F-NEW — add-walk emits new errors with new-source positions, hot path
//         stays engaged (no AddWalkRaisedErrors fallback).
//
// Pre-fixup behavior: any add-walk E0102 fell back to a full parse.
// Post-fixup: hot path stays engaged and the new error appears in
// `updated.errors` with new-source positions.
// =========================================================================

test "F-NEW-01: new E0102 from a use-before-decl in the spliced subtree" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 0; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 0;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 0;".len), .new_text = "return q;" },
        "fn f() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-NEW-02: two new E0102 entries from a binary of two use-before-decls" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 0; let q: i32 = 1; let r: i32 = 2; return q + r; }";
    const start: u32 = at(src, "return 0;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return 0;".len),
            .new_text = "return q + r;",
        },
        "fn f() -> i32 { return q + r; let q: i32 = 1; let r: i32 = 2; return q + r; }",
        true,
    );
}

test "F-NEW-03: new E0102 entries appear in DFS / source order" {
    // `q` then `r` inside the spliced expr — and the assertion oracle
    // (a parseFull on the new source) must also see them in that order.
    const src: [:0]const u8 =
        "fn f() -> i32 { return 0; let q: i32 = 1; let r: i32 = 2; return q + r; }";
    const start: u32 = at(src, "return 0;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return 0;".len),
            .new_text = "return q + r + q;",
        },
        "fn f() -> i32 { return q + r + q; let q: i32 = 1; let r: i32 = 2; return q + r; }",
        true,
    );
}

// =========================================================================
// F-SUP — suppression: edits that eliminate a pre-existing E0102, so the
//         result bucket shrinks. Complement of F-NEW. These exercise the
//         contract that the splice fixup's drop phase + the add-walk's
//         lack of emission combine to produce byte-identical bucket
//         contents relative to a fresh `parseFull` oracle.
// =========================================================================

test "F-SUP-01: replacing a use-before-decl ident with a literal drops its E0102" {
    // Inverse of F-NEW-01: base has one E0102; edit removes it.
    const src: [:0]const u8 =
        "fn f() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return q;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return q;".len), .new_text = "return 0;" },
        "fn f() -> i32 { return 0; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-SUP-02: replacing a use-before-decl with a resolvable sibling drops the E0102" {
    // The new ident resolves at the anchor's location (no before-decl),
    // so the add-walk produces no new E0102.
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return q;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return q;".len), .new_text = "return a;" },
        "fn f() -> i32 { let a = 1; return a; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-SUP-03: deleting the later declaration turns before-decl into truly-unknown — no error" {
    // Remove `let q: i32 = 1; return q;` from the tail. The remaining
    // `return q;` is now a truly-undefined ident (`lookupSymbolAnyLoc`
    // also misses) — E0102 does not fire. Proves suppression depends
    // on symbol-table state, not just textual splice.
    const src: [:0]const u8 =
        "fn f() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, " let q: i32 = 1; return q;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, " let q: i32 = 1; return q;".len),
            .new_text = "",
        },
        "fn f() -> i32 { return q; }",
        true,
    );
}

test "F-SUP-04: 10-step alternation between a use-before-decl and a clean return" {
    // Anchor-kind-stable hot edit on the same return_stmt. Every even
    // step introduces an E0102; every odd step suppresses it. The bucket
    // must track the count exactly — `parseFull` is re-run each step as
    // the oracle.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { return 0; let z: i32 = 1; return z; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const ret_start: u32 = at(base_src, "return 0;");
    const ret_len: u32 = @intCast("return 0;".len);
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "return z;" else "return 0;";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = ret_start,
            .end = ret_start + ret_len,
            .new_text = new_text,
        });
        try std.testing.expect(next.reused);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectErrorsMatch(next.errors, oracle.errors);

        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// F-MIX — drop + shift + new in one edit.
// =========================================================================

test "F-MIX-01: drop one (inside), shift one (after), append one (new)" {
    // Base: `f` body has a use-before-decl `bad`. `g` body has a
    // use-before-decl `q` strictly downstream of `f`. Edit replaces
    // `f`'s return: removes `bad` and introduces a new use-before-decl
    // reference `m` (let m declared after the early return).
    const src: [:0]const u8 =
        "fn f() -> i32 { return bad; let bad: i32 = 1; let m: i32 = 2; return bad; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return bad;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return bad;".len),
            .new_text = "return m;",
        },
        "fn f() -> i32 { return m; let bad: i32 = 1; let m: i32 = 2; return bad; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-MIX-02: kept-before, dropped-inside, kept-shifted-after" {
    // `h` early — kept. `f` middle — its E0102 dropped. `g` after — its
    // E0102 shifted by delta.
    const src: [:0]const u8 =
        "fn h() -> i32 { return e; let e: i32 = 1; return e; } fn f() -> i32 { return one + two; let one: i32 = 1; let two: i32 = 2; return one + two; } fn g() -> i32 { return tail; let tail: i32 = 1; return tail; }";
    const start: u32 = at(src, "return one + two;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, "return one + two;".len),
            .new_text = "return 0;",
        },
        "fn h() -> i32 { return e; let e: i32 = 1; return e; } fn f() -> i32 { return 0; let one: i32 = 1; let two: i32 = 2; return one + two; } fn g() -> i32 { return tail; let tail: i32 = 1; return tail; }",
        true,
    );
}

// =========================================================================
// F-ROUND — round-trip stability.
// =========================================================================

test "F-ROUND-01: edit + inverse on a clean base — error count stays at 0" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 0), base.errors.len);

    const start: u32 = at(base_src, "return 1;");
    var fwd = try Incremental.reparse(gpa, &base, .{
        .start = start,
        .end = start + @as(u32, "return 1;".len),
        .new_text = "return 2;",
    });
    defer fwd.deinit();
    try std.testing.expect(fwd.reused);
    try std.testing.expectEqual(@as(usize, 0), fwd.errors.len);

    const start2: u32 = at(fwd.source, "return 2;");
    var back = try Incremental.reparse(gpa, &fwd, .{
        .start = start2,
        .end = start2 + @as(u32, "return 2;".len),
        .new_text = "return 1;",
    });
    defer back.deinit();
    try std.testing.expect(back.reused);
    try std.testing.expectEqualStrings(base_src, back.source);
    try std.testing.expectEqual(@as(usize, 0), back.errors.len);
}

test "F-ROUND-02: introduce one error, then remove it — final count is 0" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { return 0; let q: i32 = 1; return q; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 0), base.errors.len);

    const start: u32 = at(base_src, "return 0;");
    var fwd = try Incremental.reparse(gpa, &base, .{
        .start = start,
        .end = start + @as(u32, "return 0;".len),
        .new_text = "return q;",
    });
    defer fwd.deinit();
    try std.testing.expect(fwd.reused);
    try std.testing.expectEqual(@as(usize, 1), fwd.errors.len);
    try std.testing.expectEqualStrings("E0102", fwd.errors[0].code);

    const start2: u32 = at(fwd.source, "return q;");
    var back = try Incremental.reparse(gpa, &fwd, .{
        .start = start2,
        .end = start2 + @as(u32, "return q;".len),
        .new_text = "return 0;",
    });
    defer back.deinit();
    try std.testing.expect(back.reused);
    try std.testing.expectEqualStrings(base_src, back.source);
    try std.testing.expectEqual(@as(usize, 0), back.errors.len);
}

test "F-ROUND-03: 20 successive literal cycles — no monotonic drift" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 0; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_pos: u32 = at(base_src, "0;");
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        const new_ch: u8 = '0' + (i % 10);
        const new_text = [_]u8{new_ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_pos,
            .end = lit_pos + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.errors.len);
        prev.deinit();
        prev = next;
    }
}

test "F-ROUND-04: alternating use-before-decl/clean — count tracks 1/0/1/0…" {
    const gpa = std.testing.allocator;
    // Replace the WHOLE early `return …;` so the anchor stays at
    // return_stmt every iteration (a kind-stable hot edit). Alternate
    // the body between `0` (clean) and `z` (use-before-decl).
    const base_src: [:0]const u8 =
        "fn f() -> i32 { return 0; let z: i32 = 1; return z; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const ret_start: u32 = at(base_src, "return 0;");
    const ret_len: u32 = @intCast("return 0;".len);
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "return z;" else "return 0;";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = ret_start,
            .end = ret_start + ret_len,
            .new_text = new_text,
        });
        try std.testing.expect(next.reused);
        const expected: usize = if (i % 2 == 0) 1 else 0;
        try std.testing.expectEqual(expected, next.errors.len);
        if (expected == 1) {
            try std.testing.expectEqualStrings("E0102", next.errors[0].code);
            // `return ` prefix is 7 bytes — `z` lands at ret_start + 7.
            try std.testing.expectEqual(ret_start + 7, next.errors[0].pos);
        }
        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// F-TRIVIA — trivia-only shortcut preserves error positions.
// =========================================================================

test "F-TRIVIA-01: comment swap leaves an unrelated E0102 untouched" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "// abc\nfn f() -> i32 { return q; let q: i32 = 1; return q; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(usize, 1), prev.errors.len);
    const orig_pos = prev.errors[0].pos;

    const off: u32 = at(base_src, "abc");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = off,
        .end = off + 3,
        .new_text = "xyz",
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings(
        "// xyz\nfn f() -> i32 { return q; let q: i32 = 1; return q; }",
        updated.source,
    );
    try std.testing.expectEqual(@as(usize, 1), updated.errors.len);
    try std.testing.expectEqual(orig_pos, updated.errors[0].pos);
    try std.testing.expectEqualStrings("E0102", updated.errors[0].code);
}

// =========================================================================
// F-FALLBACK — non-symbol-free anchors and full re-lower paths.
// =========================================================================

test "F-FALLBACK-01: compound_stmt anchor (full re-lower) preserves errors" {
    // Adding a new local lands on the compound_stmt anchor, which goes
    // through the full re-lower path. The fresh re-lower's errors must
    // still match a `parseFull` oracle.
    const src: [:0]const u8 =
        "fn f() -> i32 { return q; let q: i32 = 1; return q; }";
    const insert_pos: u32 = at(src, "return q;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = insert_pos, .end = insert_pos, .new_text = "let p = 1; " },
        "fn f() -> i32 { let p = 1; return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-FALLBACK-02: cross-decl edit triggers parseFull fallback" {
    const src: [:0]const u8 = "const x = 1; const y = 2;";
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = 6, .end = 20, .new_text = "a = 3; const z" },
        "const a = 3; const z = 2;",
        false,
    );
}

// =========================================================================
// F-KIND — every error code survives the fixup with `code` intact.
// =========================================================================

test "F-KIND-E0102: visit-pass code shifts cleanly" {
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1; } fn g() -> i32 { return q; let q: i32 = 1; return q; }";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = "return 1+2;" },
        "fn f() -> i32 { return 1+2; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        true,
    );
}

test "F-KIND-E0101: parser duplicate-decl code shifts cleanly" {
    // E0101 (`Parser.zig:534`): redeclaring `dup` at module scope.
    const src: [:0]const u8 =
        "fn f() -> i32 { return 1; } const dup = 1; const dup = 2;";
    const start: u32 = at(src, "return 1;");
    try runEditWithErrors(
        std.testing.allocator,
        src,
        .{ .start = start, .end = start + @as(u32, "return 1;".len), .new_text = "return 1+1;" },
        "fn f() -> i32 { return 1+1; } const dup = 1; const dup = 2;",
        true,
    );
}
