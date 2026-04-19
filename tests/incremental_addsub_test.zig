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

fn sumUseCountByName(module: *const Ast.Module, name: []const u8) u32 {
    var sum: u32 = 0;
    for (module.symbols.items) |s| {
        if (std.mem.eql(u8, s.original_name, name)) sum += s.use_count;
    }
    return sum;
}

/// Assert per-name use_count equivalence between `got` and `oracle`.
/// The Phase 2 compound_stmt / decl_stmt hot paths are append-only:
/// `got` may carry dead (use_count == 0) copies of removed-subtree
/// symbols. We therefore compare the SUM of use_counts per name; dead
/// copies contribute zero and don't disturb the match. Every name in
/// `oracle` must exist in `got` with the same live sum; any extra
/// names in `got` must have zero-sum use_counts.
fn expectUseCountsMatch(got: *const Ast.Module, oracle: *const Ast.Module) !void {
    for (oracle.symbols.items) |o| {
        const g_sum = sumUseCountByName(got, o.original_name);
        const o_sum = sumUseCountByName(oracle, o.original_name);
        if (g_sum != o_sum) {
            std.debug.print(
                "use_count sum mismatch: '{s}' got_sum={d} oracle_sum={d}\n",
                .{ o.original_name, g_sum, o_sum },
            );
            return error.UseCountMismatch;
        }
    }
    for (got.symbols.items) |g| {
        const o_sum = sumUseCountByName(oracle, g.original_name);
        if (o_sum == 0 and g.use_count != 0) {
            std.debug.print(
                "updated-only symbol '{s}' has non-zero use_count {d}\n",
                .{ g.original_name, g.use_count },
            );
            return error.DeadSymbolHasUseCount;
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

// =========================================================================
// C-* compound_stmt anchor — function-body / nested-block replacement lands
// on the in-place scope-splice path. Oracle assertion is per-symbol-name
// live-sum equivalence (append-only symbol table is a feature of this
// path, not a defect).
// =========================================================================

fn replaceBytes(
    gpa: std.mem.Allocator,
    src: [:0]const u8,
    needle: []const u8,
    replacement: []const u8,
    expect_reused: bool,
) !void {
    const pos: u32 = @intCast(std.mem.indexOf(u8, src, needle).?);
    const end: u32 = pos + @as(u32, @intCast(needle.len));
    // Build the expected new source.
    const new_src = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        src[0..pos], replacement, src[end..],
    });
    defer gpa.free(new_src);
    try runEdit(
        gpa,
        src,
        .{ .start = pos, .end = end, .new_text = replacement },
        new_src,
        expect_reused,
    );
}

test "C-01: swap body, external refs unchanged" {
    try replaceBytes(
        std.testing.allocator,
        "const k: i32 = 1; fn f() -> i32 { return k; }",
        "{ return k; }",
        "{ return k + k; }",
        true,
    );
}

test "C-02: swap body, external refs change asymmetrically" {
    try replaceBytes(
        std.testing.allocator,
        "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return a + a; }",
        "{ return a + a; }",
        "{ return b + b + b; }",
        true,
    );
}

test "C-03: swap body, drop all references to previously-used consts" {
    try replaceBytes(
        std.testing.allocator,
        "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return a + b; }",
        "{ return a + b; }",
        "{ return 7; }",
        true,
    );
}

test "C-04: swap body introduces a fresh local let" {
    try replaceBytes(
        std.testing.allocator,
        "const a: i32 = 1; fn f() -> i32 { return a; }",
        "{ return a; }",
        "{ let t = a + 1; return t; }",
        true,
    );
}

test "C-05: swap body removes a local; module consts stay live" {
    try replaceBytes(
        std.testing.allocator,
        "const a: i32 = 1; fn f() -> i32 { let x = a; return x; }",
        "{ let x = a; return x; }",
        "{ return a; }",
        true,
    );
}

test "C-06: empty body to non-empty body" {
    try replaceBytes(
        std.testing.allocator,
        "fn f() {}",
        "{}",
        "{ let q: i32 = 42; }",
        true,
    );
}

test "C-07: non-empty body to empty body" {
    try replaceBytes(
        std.testing.allocator,
        "fn f() { let q: i32 = 42; }",
        "{ let q: i32 = 42; }",
        "{}",
        true,
    );
}

test "C-08: nested compound replaced (anchor = inner compound)" {
    try replaceBytes(
        std.testing.allocator,
        "fn f() -> i32 { let a = 1; { let b = a; return b; } }",
        "{ let b = a; return b; }",
        "{ return a; }",
        true,
    );
}

test "C-09: swap body containing a for-loop (scope subtree rebuild)" {
    try replaceBytes(
        std.testing.allocator,
        "fn f() { for (var i = 0; i < 10; i = i + 1) { let x = i; } }",
        "{ for (var i = 0; i < 10; i = i + 1) { let x = i; } }",
        "{ for (var i = 0; i < 20; i = i + 1) { let y = i; } }",
        true,
    );
}

test "C-10: replace body with byte-identical text (no-op structural)" {
    // The new symbols get appended with fresh live use_counts; the old
    // ones stay dead. expectUseCountsMatch sums by name, so the oracle's
    // single live `a` equals the updated's live new-`a` plus dead-old-`a`
    // sums.
    try replaceBytes(
        std.testing.allocator,
        "fn f() -> i32 { let a = 1; return a; }",
        "{ let a = 1; return a; }",
        "{ let a = 1; return a; }",
        true,
    );
}

// =========================================================================
// F-* CST/AST invariants after a compound_stmt splice.
// =========================================================================

test "F-01: nested compound replacement keeps outer scope chain intact" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { let a = 1; { let b = a; return b; } }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const needle: []const u8 = "{ let b = a; return b; }";
    const replacement: []const u8 = "{ return a; }";
    const pos: u32 = @intCast(std.mem.indexOf(u8, base_src, needle).?);
    const end: u32 = pos + @as(u32, @intCast(needle.len));
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = pos, .end = end, .new_text = replacement,
    });
    defer updated.deinit();
    try std.testing.expect(updated.reused);

    // Count scopes in module.scope, recursively, and compare shape
    // against oracle.
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    const u_kinds = try collectScopeKinds(gpa, updated.module.scope);
    defer gpa.free(u_kinds);
    const o_kinds = try collectScopeKinds(gpa, oracle.module.scope);
    defer gpa.free(o_kinds);
    try std.testing.expectEqualSlices(u8, o_kinds, u_kinds);
}

fn collectScopeKinds(gpa: std.mem.Allocator, root: *const Ast.Scope) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try collectScopeKindsInner(gpa, root, &out);
    return out.toOwnedSlice(gpa);
}

fn collectScopeKindsInner(
    gpa: std.mem.Allocator,
    scope: *const Ast.Scope,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    try out.append(gpa, @intFromEnum(scope.kind));
    for (scope.children.items) |c| try collectScopeKindsInner(gpa, c, out);
    try out.append(gpa, 0xff); // end-of-children marker
}
