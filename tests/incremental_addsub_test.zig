//! End-to-end tests for the symbol-free add/sub hot path in
//! `Incremental.reparse`.
//!
//! Each scenario parses a base, applies ONE (or a short sequence) of
//! edits via `Incremental.reparse`, and verifies:
//!
//!   1. The resulting source matches a byte splice of the edit.
//!   2. `reused == true` on edits that should take the hot path.
//!   3. **Per-symbol `use_count`** matches a fresh `parseFull(new_src)`
//!      oracle — not just aggregate equality. A subtractive-pass bug
//!      that flips `a`'s count with `b`'s would pass an aggregate test
//!      but fail here.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

// =========================================================================
// Harness
// =========================================================================

fn useCountOf(module: *const Ast.Module, name: []const u8) u32 {
    for (module.symbols.items) |s| {
        if (std.mem.eql(u8, s.original_name, name)) return s.use_count;
    }
    return 0;
}

/// Assert that every symbol in `got` has the same `use_count` as the
/// symbol with the same `original_name` in `oracle`. Both modules must
/// have the same symbol set.
fn expectUseCountsMatch(got: *const Ast.Module, oracle: *const Ast.Module) !void {
    try std.testing.expectEqual(oracle.symbols.items.len, got.symbols.items.len);
    for (got.symbols.items) |g| {
        const o_uc = useCountOf(oracle, g.original_name);
        if (o_uc != g.use_count) {
            std.debug.print(
                "use_count mismatch: '{s}' got={d} oracle={d}\n",
                .{ g.original_name, g.use_count, o_uc },
            );
            return error.UseCountMismatch;
        }
    }
}

fn runEdit(
    gpa: std.mem.Allocator,
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
    try expectUseCountsMatch(updated.module, oracle.module);
}

// =========================================================================
// S-ADD: add-walk correctness on a freshly-spliced subtree.
// =========================================================================

test "S-ADD-01: literal swap inside a return — no ident refs touched" {
    // No symbol is referenced on either side; all use_counts stay at 0.
    try runEdit(
        std.testing.allocator,
        "fn f() -> i32 { return 0; }",
        .{ .start = 23, .end = 24, .new_text = "42" },
        "fn f() -> i32 { return 42; }",
        true,
    );
}

test "S-ADD-02: add a reference to a module-level const (return_stmt anchor)" {
    // Replace the whole `return 0;` → `return x;`. The anchor is
    // return_stmt whose kind is stable across the edit, keeping us on
    // the hot path. After: x.use_count == 1.
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return 0; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const needle: []const u8 = "return 0;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return x;" },
        new_src,
        true,
    );
}

test "S-ADD-03: add two refs to the same symbol (return_stmt anchor)" {
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return 0; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return x + x; }";
    const needle: []const u8 = "return 0;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return x + x;" },
        new_src,
        true,
    );
}

test "S-ADD-04: add refs across three distinct symbols (return_stmt anchor)" {
    const src: [:0]const u8 = "const a: i32 = 1; const b: i32 = 2; const c: i32 = 3; fn f() -> i32 { return 0; }";
    const new_src: []const u8 = "const a: i32 = 1; const b: i32 = 2; const c: i32 = 3; fn f() -> i32 { return a + b + c; }";
    const needle: []const u8 = "return 0;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return a + b + c;" },
        new_src,
        true,
    );
}

test "S-ADD-05: add a ref to a function-local let (return_stmt anchor)" {
    const src: [:0]const u8 = "fn f() -> i32 { let x = 1; return 0; }";
    const new_src: []const u8 = "fn f() -> i32 { let x = 1; return x; }";
    const needle: []const u8 = "return 0;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return x;" },
        new_src,
        true,
    );
}

// =========================================================================
// S-SUB: sub-walk correctness.
// =========================================================================

test "S-SUB-01: sub+add round-trip keeps use_count at 1 (return_stmt anchor)" {
    // Base: x referenced once inside f's body.
    // Edit: `return x;` → `return (x);`. Anchor is return_stmt whose
    // kind doesn't flip. use_count for x stays at 1
    // (sub: 1→0 on old subtree, add: 0→1 on new subtree).
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return (x); }";
    const needle: []const u8 = "return x;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return (x);" },
        new_src,
        true,
    );
}

test "S-SUB-02: sub drops the only ref to x (return_stmt anchor)" {
    // Edit: `return x;` → `return 7;`. x.use_count: 1 → 0.
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return 7; }";
    const needle: []const u8 = "return x;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return 7;" },
        new_src,
        true,
    );
}

test "S-SUB-03: sub drops multiple refs in one subtree (return_stmt anchor)" {
    // x.use_count == 3 before. Replace `return x + x + x;` with
    // `return 7;`. Anchor = return_stmt.
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x + x + x; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return 7; }";
    const needle: []const u8 = "return x + x + x;";
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = pos, .end = pos + @as(u32, @intCast(needle.len)), .new_text = "return 7;" },
        new_src,
        true,
    );
}

// =========================================================================
// S-ROUND: edit + inverse round-trip preserves every use_count exactly.
// =========================================================================

test "S-ROUND-01: edit then inverse — per-symbol use_counts unchanged" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x + x; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const initial_x_uc = useCountOf(base.module, "x");
    try std.testing.expectEqual(@as(u32, 2), initial_x_uc);

    // Forward edit: replace the whole return stmt to keep the anchor
    // kind stable across the edit (return_stmt). `return x + x;` →
    // `return x + x + x;`.
    const old_needle: []const u8 = "return x + x;";
    const bin_start: u32 = @intCast(std.mem.indexOf(u8, base_src, old_needle).?);
    var fwd = try Incremental.reparse(gpa, &base, .{
        .start = bin_start,
        .end = bin_start + @as(u32, @intCast(old_needle.len)),
        .new_text = "return x + x + x;",
    });
    defer fwd.deinit();
    try std.testing.expect(fwd.reused);
    try std.testing.expectEqual(@as(u32, 3), useCountOf(fwd.module, "x"));

    // Inverse edit: `return x + x + x;` → `return x + x;`.
    const new_needle: []const u8 = "return x + x + x;";
    const bin_start2: u32 = @intCast(std.mem.indexOf(u8, fwd.source, new_needle).?);
    var back = try Incremental.reparse(gpa, &fwd, .{
        .start = bin_start2,
        .end = bin_start2 + @as(u32, @intCast(new_needle.len)),
        .new_text = "return x + x;",
    });
    defer back.deinit();
    try std.testing.expect(back.reused);
    try std.testing.expectEqualStrings(base_src, back.source);
    try std.testing.expectEqual(@as(u32, 2), useCountOf(back.module, "x"));
}

test "S-ROUND-02: 20 successive literal churns leave every use_count at base" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x + 0; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const base_x_uc = useCountOf(prev.module, "x");

    // Find the `0` (trailing literal after `x + `).
    // After each round the literal length stays constant (we cycle 0..9),
    // so the byte offset is stable.
    const zero_pos: u32 = @intCast(std.mem.lastIndexOfScalar(u8, base_src, '0').?);
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        const new_ch: u8 = '0' + (i % 10);
        const new_text = [_]u8{new_ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = zero_pos,
            .end = zero_pos + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(base_x_uc, useCountOf(next.module, "x"));

        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// Bulk regression on real-world shader patterns — inline test cases that
// mimic the shapes seen in `tests/testdata/compute.toys/`. The corpus
// walk itself is already exercised by `incremental_corpus_test.zig` and
// `incremental_mutation_fuzz_test.zig`; this test codifies the
// per-symbol use_count invariant on a representative shape.
// =========================================================================

test "S-BULK-01: attribute argument literal bump preserves use_counts" {
    // Mimics the first integer literal inside a `@workgroup_size(…)`
    // attribute argument — a compute.toys shape that escapes the
    // function body's compound_stmt anchor path.
    try runEdit(
        std.testing.allocator,
        "const N: i32 = 7; @compute @workgroup_size(16) fn f() -> i32 { return N; }",
        .{ .start = @intCast(std.mem.indexOf(u8, "const N: i32 = 7; @compute @workgroup_size(16) fn f() -> i32 { return N; }", "16").?), .end = @intCast(std.mem.indexOf(u8, "const N: i32 = 7; @compute @workgroup_size(16) fn f() -> i32 { return N; }", "16").? + 2), .new_text = "64" },
        "const N: i32 = 7; @compute @workgroup_size(64) fn f() -> i32 { return N; }",
        true,
    );
}
