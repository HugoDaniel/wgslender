//! Unit tests for the shared `Incremental.sentinel_stub` arena.
//!
//! Every successful hot-path return from `Incremental.reparse`
//! (trivia-only, symbol-free add/sub, compound_stmt, decl_stmt)
//! installs `&Incremental.sentinel_stub` on the outgoing `prev.arena`
//! so the caller's `prev.deinit()` stays a safe no-op without an extra
//! `gpa.create(ArenaAllocator)` per keystroke.
//!
//! These tests pin the sentinel ownership contract:
//!   1. Identity on every hot path (SS1–SS4).
//!   2. Fallback still produces a real (non-sentinel) arena (SS5).
//!   3. Arena transfer is by pointer, not copy (SS6).
//!   4. Repeated hot-path reparses leave the sentinel empty (SS7).
//!   5. The sentinel pointer is shared across independent documents
//!      (SS8) and across a long mutation sequence (SS9).
//!
//! All tests run under `std.testing.allocator`, which traps on any
//! untracked `destroy` — the most important single-point test that
//! the sentinel guard in `ReparseResult.deinit` works: without the
//! guard, `gpa.destroy(&sentinel_stub)` would fire a leak/corruption
//! error on the first hot-path deinit.

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;

// ---------------------------------------------------------------------------
// SS1 — Trivia-only hot path installs the sentinel.
// ---------------------------------------------------------------------------

test "SS1: trivia-only reparse leaves prev.arena == &sentinel_stub" {
    const gpa = std.testing.allocator;
    // Edit is "// aaa" -> "// bbb" (same length, comment interior).
    const src: [:0]const u8 = "// aaa\nconst X = 1;";
    var prev = try Incremental.parseFull(gpa, src);
    // Capture the current arena pointer so we can verify transfer below.
    const prev_real_arena = prev.arena;

    // Locate "aaa".
    const a_off: u32 = @intCast(std.mem.indexOf(u8, src, "aaa").?);
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = a_off,
        .end = a_off + 3,
        .new_text = "bbb",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_real_arena, updated.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);

    // Deinit of the old (sentinel-bearing) result is a no-op on the
    // sentinel — testing.allocator will trap if we accidentally call
    // gpa.destroy on a page_allocator-owned pointer.
    prev.deinit();
}

// ---------------------------------------------------------------------------
// SS2 — Symbol-free add/sub hot path installs the sentinel.
// ---------------------------------------------------------------------------

test "SS2: symbol-free literal bump leaves prev.arena == &sentinel_stub" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, src);
    const prev_real_arena = prev.arena;

    const off: u32 = @intCast(std.mem.indexOf(u8, src, "1;").?);
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = off,
        .end = off + 1,
        .new_text = "2",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_real_arena, updated.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    prev.deinit();
}

// ---------------------------------------------------------------------------
// SS3 — compound_stmt hot path installs the sentinel.
// ---------------------------------------------------------------------------

test "SS3: compound_stmt append leaves prev.arena == &sentinel_stub" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { let a = 1; }";
    var prev = try Incremental.parseFull(gpa, src);
    const prev_real_arena = prev.arena;

    // Append ` let b = 2;` immediately before the closing `}`.
    const close_brace: u32 = @intCast(std.mem.indexOf(u8, src, "}").?);
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = close_brace,
        .end = close_brace,
        .new_text = " let b = 2;",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_real_arena, updated.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    prev.deinit();
}

// ---------------------------------------------------------------------------
// SS4 — decl_stmt hot path installs the sentinel.
// ---------------------------------------------------------------------------

test "SS4: decl_stmt literal change leaves prev.arena == &sentinel_stub" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { let x = 1; }";
    var prev = try Incremental.parseFull(gpa, src);
    const prev_real_arena = prev.arena;

    // Change `1` to `2` inside the `let x = 1;`. Anchor kind may be
    // symbol-free (literal_expr inside decl_stmt) OR decl_stmt itself,
    // depending on where the driver splits the anchor; either way the
    // sentinel is installed.
    const off: u32 = @intCast(std.mem.indexOf(u8, src, "1;").?);
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = off,
        .end = off + 1,
        .new_text = "2",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_real_arena, updated.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    prev.deinit();
}

// ---------------------------------------------------------------------------
// SS5 — Fallback path returns a fresh real arena (not the sentinel).
// ---------------------------------------------------------------------------

test "SS5: fallback reparse returns a fresh non-sentinel arena" {
    const gpa = std.testing.allocator;
    // Adding a whole new top-level decl at offset 0 crosses the module-
    // item boundary — no single-anchor reparse applies, so the driver
    // falls back to parseFull and returns a brand-new arena.
    const src: [:0]const u8 = "const X = 1;";
    var prev = try Incremental.parseFull(gpa, src);
    defer prev.deinit();

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = 0,
        .end = 0,
        .new_text = "const Y = 2; ",
    });
    defer updated.deinit();

    try std.testing.expect(!updated.reused);
    // Fallback produces a real arena — definitely not the shared stub.
    try std.testing.expect(updated.arena != &Incremental.sentinel_stub);
    // And prev keeps its own real arena (nothing transferred).
    try std.testing.expect(prev.arena != &Incremental.sentinel_stub);
}

// ---------------------------------------------------------------------------
// SS6 — The arena pointer is transferred by identity, not by copy.
// ---------------------------------------------------------------------------

test "SS6: hot-path return transfers the exact prev.arena pointer to updated" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, src);
    const captured_prev_arena = prev.arena;

    const off: u32 = @intCast(std.mem.indexOf(u8, src, "1;").?);
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = off,
        .end = off + 1,
        .new_text = "9",
    });
    defer updated.deinit();

    // Identity equality: `updated.arena` must be the exact pointer
    // that was on `prev.arena` before the call — not a copy.
    try std.testing.expectEqual(captured_prev_arena, updated.arena);
    // And `prev.arena` is now the sentinel (no longer the captured one).
    try std.testing.expect(prev.arena != captured_prev_arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev.arena);
    prev.deinit();
}

// ---------------------------------------------------------------------------
// SS7 — Long burst: 100 hot-path reparses never grow the sentinel and
// never leak on testing.allocator.
// ---------------------------------------------------------------------------

test "SS7: sentinel stays empty across a 100-edit burst" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "fn f() -> i32 { return 0; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    // Sentinel baseline: empty before any hot-path run.
    try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());

    // Over a 100-edit burst the coalescing watermark may occasionally
    // force a fallback parseFull (producing a fresh real arena), but
    // the majority of edits stay on the hot path. For *every* edit —
    // fallback or not — the sentinel must not gain bytes, since only
    // the shortcut sites ever write `&sentinel_stub` and none of them
    // allocate into it. We therefore require: most edits take the hot
    // path AND the sentinel capacity never changes.
    var hot_count: u32 = 0;
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
        if (next.reused) {
            hot_count += 1;
            // Hot path: cur.arena was swapped to the sentinel.
            try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        } else {
            // Fallback: cur.arena is still its original real arena, not
            // the sentinel. deinit must destroy it normally.
            try std.testing.expect(cur.arena != &Incremental.sentinel_stub);
        }
        // Sentinel capacity unchanged on every iteration.
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }

    // Vast majority of edits should stay on the hot path.
    try std.testing.expect(hot_count >= 90);
    try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
}

// ---------------------------------------------------------------------------
// SS8 — The sentinel pointer is shared across independent documents.
// ---------------------------------------------------------------------------

test "SS8: sentinel pointer identity is shared across two documents" {
    const gpa = std.testing.allocator;
    const src_a: [:0]const u8 = "fn a() -> i32 { return 1; }";
    const src_b: [:0]const u8 = "fn b() -> i32 { return 7; }";

    var prev_a = try Incremental.parseFull(gpa, src_a);
    var prev_b = try Incremental.parseFull(gpa, src_b);

    const off_a: u32 = @intCast(std.mem.indexOf(u8, src_a, "1;").?);
    const off_b: u32 = @intCast(std.mem.indexOf(u8, src_b, "7;").?);

    var upd_a = try Incremental.reparse(gpa, &prev_a, .{
        .start = off_a,
        .end = off_a + 1,
        .new_text = "2",
    });
    defer upd_a.deinit();
    var upd_b = try Incremental.reparse(gpa, &prev_b, .{
        .start = off_b,
        .end = off_b + 1,
        .new_text = "8",
    });
    defer upd_b.deinit();

    // Both documents' old results now point at the same shared sentinel.
    try std.testing.expectEqual(prev_a.arena, prev_b.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev_a.arena);
    try std.testing.expectEqual(&Incremental.sentinel_stub, prev_b.arena);

    // Both deinits are safe — the guard short-circuits on both, so
    // testing.allocator sees no mismatched destroy.
    prev_a.deinit();
    prev_b.deinit();
}

// ---------------------------------------------------------------------------
// SS9 — Mixed hot-path sequence (trivia → symbol-free → compound →
// decl) all install the sentinel, and the sentinel stays empty throughout.
// ---------------------------------------------------------------------------

test "SS9: mixed-path sequence preserves sentinel invariants" {
    const gpa = std.testing.allocator;
    const base: [:0]const u8 = "// tag\nfn f() { let a = 1; }";
    var cur = try Incremental.parseFull(gpa, base);
    defer cur.deinit();

    // Path 1: trivia-only (same-length comment edit).
    {
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "tag").?);
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = off,
            .end = off + 3,
            .new_text = "TAG",
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }

    // Path 2: symbol-free literal bump on the `let a = 1;` initializer.
    {
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "1;").?);
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = off,
            .end = off + 1,
            .new_text = "9",
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }

    // Path 3: compound_stmt append — add a new `let b = 2;` before `}`.
    {
        const close_brace: u32 = @intCast(std.mem.lastIndexOfScalar(u8, cur.source, '}').?);
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = close_brace,
            .end = close_brace,
            .new_text = " let b = 2;",
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }

    // Path 4: decl_stmt — rename the `b` identifier in `let b = 2;`.
    {
        const off: u32 = @intCast(std.mem.indexOf(u8, cur.source, "let b").?);
        const b_off: u32 = off + @as(u32, @intCast("let ".len));
        const next = try Incremental.reparse(gpa, &cur, .{
            .start = b_off,
            .end = b_off + 1,
            .new_text = "z",
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(&Incremental.sentinel_stub, cur.arena);
        try std.testing.expectEqual(@as(usize, 0), Incremental.sentinel_stub.queryCapacity());
        cur.deinit();
        cur = next;
    }
}
