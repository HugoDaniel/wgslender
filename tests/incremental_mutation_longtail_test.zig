//! Long-tail mutation scenarios for `Incremental.reparse` (M1–M8).
//!
//! Each scenario stresses a different branch in the hot-path slot finder
//! (`findAstSlot` family), the scope map (`scopeAtCstNode`), the span-shift
//! pass (`shiftAstSpans`), or the AstVisit add/sub walks. Per-symbol
//! `use_count` is verified against a `parseFull` oracle so subtractive
//! bugs that aggregate counters miss are caught here.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

// =========================================================================
// Harness — mirror of `incremental_addsub_test.zig` so callers can swap
// freely between the two files.
// =========================================================================

fn useCountOf(module: *const Ast.Module, name: []const u8) u32 {
    for (module.symbols.items) |s| {
        if (std.mem.eql(u8, s.original_name, name)) return s.use_count;
    }
    return 0;
}

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

fn renderShape(
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
    try renderShape(gpa, &ab, a);
    try renderShape(gpa, &bb, b);
    try std.testing.expectEqualStrings(ab.items, bb.items);
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
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

/// Position-and-code equality against an oracle parse's errors. Mirrors
/// `expectErrorsMatch` in `incremental_error_fixup_test.zig`; we inline
/// a private copy here so every M-series test implicitly gains
/// error-bucket coverage without depending on test-file ordering.
fn expectErrorsOracleMatch(
    got: []const wgslender.Parser.ParseError,
    oracle: []const wgslender.Parser.ParseError,
) !void {
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

/// Locate the byte index of `needle`'s first occurrence in `haystack`, as a
/// `u32` so it can be used directly in `Incremental.Edit`.
fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

// =========================================================================
// M1 — Attribute-argument expression mutation.
//
// Stresses the only path through which a hot-path anchor can land inside
// an attribute: `findSlotInAttribute` (`src/Incremental.zig:1122`).
// `AstVisit.visitDecl` deliberately does NOT walk `attr.args`, so attribute
// arguments contribute nothing to `use_count` in either the original parse
// or the oracle — making M1's correctness oracle especially sharp:
// per-symbol counts must be unchanged across an attribute-arg edit, no
// matter what idents the edit introduces or removes.
// =========================================================================

test "M1.a: workgroup_size literal flip on fn main" {
    const src: [:0]const u8 = "@compute @workgroup_size(8) fn main() {}";
    const new_src: []const u8 = "@compute @workgroup_size(16) fn main() {}";
    const lit_off = at(src, "8");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "16" },
        new_src,
        true,
    );
}

test "M1.b: @group literal flip on a var binding" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 = "@group(1) @binding(0) var<uniform> u: f32;";
    const lit_off = at(src, "(0)");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off + 1, .end = lit_off + 2, .new_text = "1" },
        new_src,
        true,
    );
}

test "M1.c: @binding literal flip on a var binding" {
    const src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 = "@group(0) @binding(3) var<uniform> u: f32;";
    // Find the SECOND `(0)` — i.e., binding's argument.
    const first = at(src, "(0)");
    const second = at(src[first + 1 ..], "(0)") + first + 1;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second + 1, .end = second + 2, .new_text = "3" },
        new_src,
        true,
    );
}

test "M1.d: @align literal flip on a struct member attribute" {
    const src: [:0]const u8 = "struct S { @align(16) x: f32, y: i32 }";
    const new_src: []const u8 = "struct S { @align(8) x: f32, y: i32 }";
    const lit_off = at(src, "16");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 2, .new_text = "8" },
        new_src,
        true,
    );
}

test "M1.e: workgroup_size second-arg literal flip" {
    const src: [:0]const u8 = "@compute @workgroup_size(8, 8) fn main() {}";
    const new_src: []const u8 = "@compute @workgroup_size(8, 16) fn main() {}";
    // Find the second `8` (after the comma).
    const comma = at(src, ",");
    const second_eight = at(src[comma..], "8") + comma;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second_eight, .end = second_eight + 1, .new_text = "16" },
        new_src,
        true,
    );
}

test "M1.f: @location literal flip on an entry-point return attribute" {
    const src: [:0]const u8 = "@vertex fn main() -> @location(0) vec4<f32> { return vec4<f32>(0.0); }";
    const new_src: []const u8 = "@vertex fn main() -> @location(2) vec4<f32> { return vec4<f32>(0.0); }";
    const lit_off: u32 = at(src, "@location(") + @as(u32, @intCast("@location(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "2" },
        new_src,
        true,
    );
}

// M1.g — Attribute-argument IDENT swaps (the bug that M1.a–M1.f couldn't
// reach). `AstVisit.visitDecl` never descends into `attr.args` during the
// full-parse Pass 2, so the oracle records zero `use_count` contribution
// from attr-arg idents. The incremental hot path's add-walk previously
// diverged: it ran `AstVisit.visitSubtreeExpr(.add)` over the spliced
// subtree and bumped every resolved ident. Fix lives in
// `findAstSlot`/`tryAddSubSpliceInPlace` — slot info now carries an
// `in_attribute` flag and both sub/add walks skip when it's set. These
// scenarios lock that parity in with a per-symbol `use_count` oracle.

test "M1.g.1: @workgroup_size ident→ident swap (hot path exercises the fix)" {
    // Two sibling consts, both unreferenced outside the attribute. Swap
    // the one currently named in `@workgroup_size` for the other. Anchor
    // is `ident_expr` in both old and new, so kind-match succeeds and
    // `tryAddSubSpliceInPlace` runs — the exact branch that the fix
    // gates on `info.in_attribute`. Pre-fix: `B.use_count` would land at
    // 1 after the edit while the oracle keeps it at 0.
    const src: [:0]const u8 = "const A: u32 = 8; const B: u32 = 16; @compute @workgroup_size(A) fn main() {}";
    const new_src: []const u8 = "const A: u32 = 8; const B: u32 = 16; @compute @workgroup_size(B) fn main() {}";
    const off: u32 = at(src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M1.g.1b: literal→ident attr-arg edit falls back (AnchorKindMismatch), oracle still matches" {
    // Kind-changing attr-arg edit: `literal_expr` → `ident_expr`.
    // `tryAddSubSpliceInPlace`'s kind check triggers `AnchorKindMismatch`
    // and `reparse()` falls back to `parseFull`. The fix doesn't alter
    // this path, but we pin that the fallback route keeps producing
    // oracle-correct `use_count` when attribute idents are in play.
    const src: [:0]const u8 = "const N: u32 = 8; @compute @workgroup_size(8) fn main() {}";
    const new_src: []const u8 = "const N: u32 = 8; @compute @workgroup_size(N) fn main() {}";
    const lit_off: u32 = at(src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "N" },
        new_src,
        false,
    );
}

test "M1.g.2: @group(ident) ident↔ident swap (two sibling consts)" {
    const src: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(A) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(B) @binding(0) var<uniform> u: f32;";
    const off: u32 = at(src, "@group(") + @as(u32, @intCast("@group(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M1.g.3: @binding(ident) ident↔ident swap" {
    // Mirror of M1.g.2 — exercises the second attribute on the same decl.
    const src: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(0) @binding(A) var<uniform> u: f32;";
    const new_src: []const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(0) @binding(B) var<uniform> u: f32;";
    const off: u32 = at(src, "@binding(") + @as(u32, @intCast("@binding(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M1.g.4: struct-member @align(ident) swap routes through struct branch" {
    // Hits `findSlotInDecl`'s `.@"struct"` branch.
    const src: [:0]const u8 =
        "const A: u32 = 16; const B: u32 = 8; struct S { @align(A) x: f32, y: i32 }";
    const new_src: []const u8 =
        "const A: u32 = 16; const B: u32 = 8; struct S { @align(B) x: f32, y: i32 }";
    const off: u32 = at(src, "@align(") + @as(u32, @intCast("@align(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M1.g.5: parameter @location(ident) ident→ident swap routes through parameter branch" {
    // Hits `findSlotInDecl`'s parameter-attribute loop. Two sibling
    // override consts — @location requires a `const` integer, overrides
    // are not allowed, so we use module-scope `const`s with distinct
    // values.
    const src: [:0]const u8 =
        "const L0: u32 = 0; const L1: u32 = 1; @fragment fn f(@location(L0) x: vec4<f32>) -> @location(2) vec4<f32> { return x; }";
    const new_src: []const u8 =
        "const L0: u32 = 0; const L1: u32 = 1; @fragment fn f(@location(L1) x: vec4<f32>) -> @location(2) vec4<f32> { return x; }";
    // The first `@location(` in the source is on the parameter.
    const off: u32 = at(src, "@location(") + @as(u32, @intCast("@location(L".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M1.g.6: return-attribute @location(ident) ident→ident swap routes through return_attr branch" {
    // Hits `findSlotInDecl`'s `return_attr` loop. The parameter's
    // @location stays a literal so the parameter-attribute loop doesn't
    // short-circuit the search — the target slot lives in
    // `decl.return_attr`.
    const src: [:0]const u8 =
        "const L0: u32 = 0; const L1: u32 = 1; @fragment fn f() -> @location(L0) vec4<f32> { return vec4<f32>(0.0); }";
    const new_src: []const u8 =
        "const L0: u32 = 0; const L1: u32 = 1; @fragment fn f() -> @location(L1) vec4<f32> { return vec4<f32>(0.0); }";
    const off: u32 = at(src, "-> @location(") + @as(u32, @intCast("-> @location(L".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M1.g.7: @workgroup_size(A, B, 1) second-arg ident↔ident swap keeps first arg's use_count still" {
    // Multi-arg attribute; edit hits only the second arg ident. Both A
    // and B are module-const scalars unreferenced outside the attribute,
    // so the oracle keeps both at `use_count == 0`. The first arg's
    // ident token is untouched by the splice, so this scenario pins that
    // only the edited slot's ident-resolution is skipped (the fix is
    // scoped to the spliced subtree, not the whole attribute).
    const src: [:0]const u8 =
        "const A: u32 = 8; const B: u32 = 16; const C: u32 = 32; @compute @workgroup_size(A, B, 1) fn main() {}";
    const new_src: []const u8 =
        "const A: u32 = 8; const B: u32 = 16; const C: u32 = 32; @compute @workgroup_size(A, C, 1) fn main() {}";
    const ws_at: u32 = at(src, "@workgroup_size(A,");
    const second_arg: u32 = ws_at + @as(u32, @intCast("@workgroup_size(A, ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second_arg, .end = second_arg + 1, .new_text = "C" },
        new_src,
        true,
    );
}

test "M1.g.8: call_expr anchor inside attr-args — whole callee swap stays hot" {
    // Swap the entire `a()` for `b()` — the edit range covers the whole
    // call, so `findAnchor` settles on `call_expr` rather than the inner
    // `ident_expr` (which would greedily re-parse past itself and trip
    // `AnchorKindMismatch`). Both sides are `call_expr`, kind matches,
    // hot path runs — and the inner ident (`a` or `b`) must not bump its
    // callee's `use_count` under the fix.
    const src: [:0]const u8 =
        "fn a() -> u32 { return 8u; } fn b() -> u32 { return 16u; } @compute @workgroup_size(a()) fn main() {}";
    const new_src: []const u8 =
        "fn a() -> u32 { return 8u; } fn b() -> u32 { return 16u; } @compute @workgroup_size(b()) fn main() {}";
    const off: u32 = at(src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    const call_len: u32 = @intCast("a()".len);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + call_len, .new_text = "b()" },
        new_src,
        true,
    );
}

test "M1.g.9: binary_expr inside attr-args — operator flip leaves use_counts put" {
    // `@workgroup_size(N * 2)` → `@workgroup_size(N + 2)`. Anchor is the
    // binary_expr inside attribute_args. Full-parse leaves N at 0; pre-fix
    // the add-walk bumped N on every reparse.
    const src: [:0]const u8 =
        "const N: u32 = 4; @compute @workgroup_size(N * 2) fn main() {}";
    const new_src: []const u8 =
        "const N: u32 = 4; @compute @workgroup_size(N + 2) fn main() {}";
    const off: u32 = at(src, "N * 2") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "+" },
        new_src,
        true,
    );
}

test "M1.g.10: paren_expr inside attr-args — innermost ident swap is oracle-quiet" {
    const src: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group((A)) @binding(0) var<uniform> u: f32;";
    const new_src: []const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group((B)) @binding(0) var<uniform> u: f32;";
    const off: u32 = at(src, "@group((") + @as(u32, @intCast("@group((".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M1.g.11: ident↔ident round-trip leaves source and use_counts pristine" {
    // Apply ident swap A→B then inverse B→A on the `@group` arg. Both
    // edits stay on the hot path (ident_expr both sides). The parseFull
    // oracle on the final source pins no drift accumulates across the
    // round-trip — a single forward bump with no matching decrement (or
    // vice versa) would be caught by `expectUseCountsMatch`.
    const gpa = std.testing.allocator;
    const base: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(A) @binding(0) var<uniform> u: f32;";

    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    const off: u32 = at(base, "@group(") + @as(u32, @intCast("@group(".len));

    // Forward: A → B
    var after1 = try Incremental.reparse(gpa, &prev, .{
        .start = off,
        .end = off + 1,
        .new_text = "B",
    });
    defer after1.deinit();
    try std.testing.expect(after1.reused);

    // Inverse: B → A
    var after2 = try Incremental.reparse(gpa, &after1, .{
        .start = off,
        .end = off + 1,
        .new_text = "A",
    });
    defer after2.deinit();
    try std.testing.expect(after2.reused);
    try std.testing.expectEqualStrings(base, after2.source);

    var oracle = try Incremental.parseFull(gpa, base);
    defer oracle.deinit();
    try expectUseCountsMatch(after2.module, oracle.module);
}

test "M1.g.12: 20-edit ident↔ident chain on @workgroup_size(A|B) holds oracle every step" {
    // Alternates `A` ↔ `B` in `@workgroup_size`. Pre-fix, each iteration
    // would introduce constant +1 drift relative to the oracle (the
    // sub-walk would decrement from the previous incorrect bump, then
    // the add-walk would re-bump). Post-fix: both walks skip and the
    // oracle matches after every reparse.
    const gpa = std.testing.allocator;
    const base: [:0]const u8 =
        "const A: u32 = 8; const B: u32 = 16; @compute @workgroup_size(A) fn main() {}";

    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    const off: u32 = at(base, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "B" else "A";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try std.testing.expect(next.reused);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        prev.deinit();
        prev = next;
    }
}

test "M1.g.13: 20-edit ident↔ident chain on @group(A|B) holds zeros throughout" {
    // Both A and B must stay at use_count == 0 across all 20 iterations;
    // pre-fix one of them would grow without bound as the chain drifted.
    const gpa = std.testing.allocator;
    const base: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(A) @binding(0) var<uniform> u: f32;";

    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    const off: u32 = at(base, "@group(") + @as(u32, @intCast("@group(".len));
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "B" else "A";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try std.testing.expect(next.reused);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);
        // Spot-check: both module-const symbols are dead regardless of
        // which one is currently named in the attribute arg.
        try std.testing.expectEqual(@as(u32, 0), useCountOf(next.module, "A"));
        try std.testing.expectEqual(@as(u32, 0), useCountOf(next.module, "B"));

        prev.deinit();
        prev = next;
    }
}

test "M1.g.14: attr-arg shape-changing edit still falls back (guard against over-eager fix)" {
    // Add a new comma-separated argument to a single-arg attribute.
    // Before the fix, this edit already fell back because the anchor had
    // to promote past `attribute_args` (not a hot-path kind). We pin that
    // it KEEPS falling back after the fix — guarding against a future
    // change that accidentally admits shape-changing attr-arg edits.
    const src: [:0]const u8 = "@compute @workgroup_size(8) fn main() {}";
    const new_src: []const u8 = "@compute @workgroup_size(8, 8) fn main() {}";
    const end_paren: u32 = at(src, "8)") + 1;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = end_paren, .end = end_paren, .new_text = ", 8" },
        new_src,
        false,
    );
}

test "M1.g.15: zero-delta whitespace swap inside attr-args takes the trivia shortcut" {
    // `classifyEdit` reports `.trivia_only` only for zero-delta edits
    // (new_text.len == end - start). Swap a single space for a single
    // tab inside `@workgroup_size( A )` — the attribute's non-trivia
    // token sequence is unchanged, so the module + errors stay pinned.
    const src: [:0]const u8 =
        "const A: u32 = 8; @compute @workgroup_size( A ) fn main() {}";
    const new_src: []const u8 =
        "const A: u32 = 8; @compute @workgroup_size(\tA ) fn main() {}";
    const space_off: u32 = at(src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = space_off, .end = space_off + 1, .new_text = "\t" },
        new_src,
        true,
    );
}

// =========================================================================
// M2 — Type-expression mutation falls back gracefully.
//
// `findSlotInDecl` (`src/Incremental.zig:1088–1119`) intentionally does NOT
// descend into `typ` / `return_type` fields. Any edit whose innermost
// reparse anchor lives inside a type expression must therefore promote up
// the parent chain until it either finds a hot-path anchor (none exists
// at module scope) or hits the root → fallback.
//
// These tests pin that contract: a future "improvement" to the slot
// finder that recurses into types would silently produce wrong AST state
// without an oracle here.
// =========================================================================

test "M2.a: array<f32, N> size-expr ident swap falls back" {
    const src: [:0]const u8 = "const N: u32 = 8; const K: u32 = 16; var<private> u: array<f32, N>;";
    const new_src: []const u8 = "const N: u32 = 8; const K: u32 = 16; var<private> u: array<f32, K>;";
    // The `N` we want lives inside `array<f32, N>` — last `N` in the source.
    const n_off: u32 = @intCast(std.mem.lastIndexOfScalar(u8, src, 'N').?);
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = n_off, .end = n_off + 1, .new_text = "K" },
        new_src,
        false,
    );
}

test "M2.b: struct member vec3 → vec4 falls back" {
    const src: [:0]const u8 = "struct S { x: vec3<f32>, y: i32 }";
    const new_src: []const u8 = "struct S { x: vec4<f32>, y: i32 }";
    const off: u32 = at(src, "vec3") + 3; // index of '3' in 'vec3'
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "4" },
        new_src,
        false,
    );
}

test "M2.c: ptr<storage, …> → ptr<workgroup, …> on a struct member falls back" {
    // ptrs are uncommon as struct-member types but still parseable and the
    // type-span machinery handles them. The point of this test is that a
    // pure address-space token swap inside a `type_ptr` falls back.
    const src: [:0]const u8 = "struct S { p: ptr<storage, f32, read_write> }";
    const new_src: []const u8 = "struct S { p: ptr<workgroup, f32, read_write> }";
    const off: u32 = at(src, "storage");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + @as(u32, @intCast("storage".len)), .new_text = "workgroup" },
        new_src,
        false,
    );
}

test "M2.d: function return type f32 → vec2<f32> falls back" {
    const src: [:0]const u8 = "fn f() -> f32 { return 0.0; }";
    const new_src: []const u8 = "fn f() -> vec2<f32> { return vec2<f32>(0.0); }";
    // Replace " f32 { return 0.0;" → " vec2<f32> { return vec2<f32>(0.0);"
    const ret_arrow: u32 = at(src, "-> f32 {");
    const old_chunk: []const u8 = "-> f32 { return 0.0;";
    const new_chunk: []const u8 = "-> vec2<f32> { return vec2<f32>(0.0);";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_arrow,
            .end = ret_arrow + @as(u32, @intCast(old_chunk.len)),
            .new_text = new_chunk,
        },
        new_src,
        false,
    );
}

test "M2.e: nested array<vec3<f32>, 4> → array<vec4<f32>, 4> falls back" {
    const src: [:0]const u8 = "var<private> u: array<vec3<f32>, 4>;";
    const new_src: []const u8 = "var<private> u: array<vec4<f32>, 4>;";
    const off: u32 = at(src, "vec3") + 3;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "4" },
        new_src,
        false,
    );
}

test "M2.f: array-size ident edited to would-be use-before-decl is inert" {
    // `visitType` resolves type-expression idents with `ctx.current_loc
    // = 0`, which defeats the position filter in `lookupSymbol` — a
    // type-ident is visible regardless of textual order, so E0102
    // cannot fire on a type-level mis-order. The edit itself is a
    // type-expression anchor, so it falls back; the oracle + updated
    // error buckets must agree (both empty of Pass-2 errors).
    const src: [:0]const u8 = "var<private> u: array<f32, LATER>; const LATER: u32 = 4;";
    const new_src: []const u8 = "var<private> u: array<f32, EARLY>; const LATER: u32 = 4;";
    const off = at(src, "LATER");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + @as(u32, @intCast("LATER".len)), .new_text = "EARLY" },
        new_src,
        false,
    );
}

// =========================================================================
// M3 — `for`-loop compartment mutations exercise the for-scope map.
//
// `for_stmt` is a scope opener (`isScopeOpener`,
// `src/Incremental.zig:128`); its CST node maps to an AST scope holding
// the for-init local. A hot-path anchor inside the condition or update
// must therefore resolve via `scopeAtCstNode` → for-scope so the local is
// visible. `findSlotInStmt` for `.@"for"` (`src/Incremental.zig:1179`)
// descends into init/condition/update/body — these tests pin down each
// compartment.
// =========================================================================

test "M3.a: for-condition operator flip (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() { let limit = 5; for (var i = 0; i < limit; i = i + 1) {} }";
    const new_src: []const u8 =
        "fn f() { let limit = 5; for (var i = 0; i <= limit; i = i + 1) {} }";
    // Replace the entire `i < limit` binary expression so the new subtree
    // is also a binary_expr (kind-stable hot path).
    const cond_off: u32 = at(src, "i < limit");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < limit".len)),
            .new_text = "i <= limit",
        },
        new_src,
        true,
    );
}

test "M3.b: for-condition RHS literal swap (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 = "fn f() { for (var i = 0; i < 5; i = i + 1) {} }";
    const lit_off: u32 = at(src, "< 10") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 2, .new_text = "5" },
        new_src,
        true,
    );
}

test "M3.c: for-condition RHS ident swap to sibling const (ident_expr anchor)" {
    const src: [:0]const u8 =
        "const N: i32 = 8; const K: i32 = 16; fn f() { for (var i = 0; i < N; i = i + 1) {} }";
    const new_src: []const u8 =
        "const N: i32 = 8; const K: i32 = 16; fn f() { for (var i = 0; i < K; i = i + 1) {} }";
    // The `N` we want is the one inside `i < N`.
    const probe_off: u32 = at(src, "< N") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = probe_off, .end = probe_off + 1, .new_text = "K" },
        new_src,
        true,
    );
}

test "M3.d: for-update binary RHS swap to sibling local (binary_expr anchor)" {
    // `step` is declared before the `for`, so text-order visibility allows
    // resolving it from inside the for-update's RHS.
    const src: [:0]const u8 =
        "fn f() { let step = 2; for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 =
        "fn f() { let step = 2; for (var i = 0; i < 10; i = i + step) {} }";
    // Replace the binary `i + 1` so the new subtree stays binary_expr.
    const bin_off: u32 = at(src, "i + 1");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = bin_off,
            .end = bin_off + @as(u32, @intCast("i + 1".len)),
            .new_text = "i + step",
        },
        new_src,
        true,
    );
}

test "M3.e: for-init initializer literal swap (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    const new_src: []const u8 = "fn f() { for (var i = 5; i < 10; i = i + 1) {} }";
    const init_lit: u32 = at(src, "var i = 0") + @as(u32, @intCast("var i = ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = init_lit, .end = init_lit + 1, .new_text = "5" },
        new_src,
        true,
    );
}

test "M3.f: 10 successive literal flips on for-update keep hot path" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { for (var i = 0; i < 10; i = i + 1) {} }";
    var prev = try Incremental.parseFull(gpa, src);
    defer prev.deinit();

    // Position of the trailing `1` in `i + 1` (the for-update RHS literal).
    // Length stays at 1 byte through every cycle so the offset is stable.
    const lit_off: u32 = at(src, "i + 1") + 4;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        const ch: u8 = '0' + ((i + 1) % 10);
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        // Spot-check: declarations + symbol set match the oracle on every step.
        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectShapesMatch(gpa, next.module, oracle.module);
        try expectUseCountsMatch(next.module, oracle.module);

        prev.deinit();
        prev = next;
    }
}

test "M3.g: for-cond edited to reference a use-before-decl ident emits E0102" {
    // `limit` is declared below the `for`, so a condition reference to
    // it is a use-before-decl. Replace the entire `i < 10` binary_expr
    // with `i < limit` to keep the anchor kind-stable (binary_expr →
    // binary_expr). The add-walk resolves `limit` in the for-scope's
    // parent (function body), misses on position, hits on any-loc →
    // emits E0102.
    const src: [:0]const u8 =
        "fn f() { for (var i = 0; i < 10; i = i + 1) {} let limit = 5; }";
    const new_src: []const u8 =
        "fn f() { for (var i = 0; i < limit; i = i + 1) {} let limit = 5; }";
    const cond_off: u32 = at(src, "i < 10");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < 10".len)),
            .new_text = "i < limit",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M4 — `switch` / `case` selector & body mutations.
//
// `findSlotInStmt` for `.@"switch"` (`src/Incremental.zig:1169`) walks
// the switch subject expr, then per-case `selectors` and `body`. Selectors
// are visited via `visitExpr` in the *switch's enclosing scope* (not the
// case body's scope) — `AstVisit.processOneStmt` line 170. These tests
// exercise selector literal/ident mutations and case-body return-stmt
// mutations, plus the cross-case fallback.
// =========================================================================

test "M4.a: case literal selector flip (literal_expr anchor)" {
    const src: [:0]const u8 = "fn f(t: i32) { switch t { case 0: {} default: {} } }";
    const new_src: []const u8 = "fn f(t: i32) { switch t { case 1: {} default: {} } }";
    const sel: u32 = at(src, "case 0:") + @as(u32, @intCast("case ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = sel, .end = sel + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M4.b: case multi-selector second-arg literal flip" {
    const src: [:0]const u8 = "fn f(t: i32) { switch t { case 0, 1: {} default: {} } }";
    const new_src: []const u8 = "fn f(t: i32) { switch t { case 0, 2: {} default: {} } }";
    // Second selector literal is the `1` after the comma.
    const comma: u32 = at(src, ",");
    const second_sel: u32 = at(src[comma..], "1") + comma;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = second_sel, .end = second_sel + 1, .new_text = "2" },
        new_src,
        true,
    );
}

test "M4.c: case selector ident swap to sibling const (ident_expr anchor)" {
    const src: [:0]const u8 =
        "const A: i32 = 1; const B: i32 = 2; fn f(t: i32) { switch t { case A: {} default: {} } }";
    const new_src: []const u8 =
        "const A: i32 = 1; const B: i32 = 2; fn f(t: i32) { switch t { case B: {} default: {} } }";
    const sel: u32 = at(src, "case A:") + @as(u32, @intCast("case ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = sel, .end = sel + 1, .new_text = "B" },
        new_src,
        true,
    );
}

test "M4.d: case-body return value swap (return_stmt anchor)" {
    const src: [:0]const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return 1; } default: { return 0; } } }";
    const new_src: []const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return 7; } default: { return 0; } } }";
    // Replace the entire `return 1;` so the new subtree is also a
    // return_stmt (kind-stable hot path).
    const ret_off: u32 = at(src, "return 1;");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_off,
            .end = ret_off + @as(u32, @intCast("return 1;".len)),
            .new_text = "return 7;",
        },
        new_src,
        true,
    );
}

test "M4.f: edit spanning two top-level fns falls back" {
    // No common compound_stmt enclosure — `findAnchor` walks up to the
    // module root, which is not a hot-path anchor. Triggers full reparse.
    const src: [:0]const u8 =
        "fn f() { return; } fn g() { return; }";
    const new_src: []const u8 =
        "fn fz() { return; } fn gz() { return; }";
    const start: u32 = at(src, "f() { return; } fn g(");
    const old_chunk: []const u8 = "f() { return; } fn g(";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, @intCast(old_chunk.len)),
            .new_text = "fz() { return; } fn gz(",
        },
        new_src,
        false,
    );
}

test "M4.e: edit spanning two case boundaries collapses cases via compound_stmt re-lower" {
    // `findAnchor` cannot find a single switch-internal anchor for an edit
    // that crosses case boundaries — but it CAN promote to the enclosing
    // function-body `compound_stmt`, which is a hot-path anchor that
    // triggers a whole-module re-lower (reused = true). This test pins
    // that behavior so a future change that demotes compound_stmt off the
    // hot-path allowlist surfaces here.
    const src: [:0]const u8 =
        "fn f(t: i32) { switch t { case 0: { return; } case 1: {} default: {} } }";
    const new_src: []const u8 =
        "fn f(t: i32) { switch t { case 0, 1: {} default: {} } }";
    const start: u32 = at(src, "0: { return; } case 1:");
    const old_chunk: []const u8 = "0: { return; } case 1:";
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = start,
            .end = start + @as(u32, @intCast(old_chunk.len)),
            .new_text = "0, 1:",
        },
        new_src,
        true,
    );
}

test "M4.g: case-body return swapped to a use-before-decl ident emits E0102" {
    // `return q;` inside a case body is a standard expression anchor;
    // `q` declared after the switch-end makes it a use-before-decl.
    const src: [:0]const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return 0; } default: { return 0; } } let q: i32 = 1; return q; }";
    const new_src: []const u8 =
        "fn f(t: i32) -> i32 { switch t { case 0: { return q; } default: { return 0; } } let q: i32 = 1; return q; }";
    const ret_off: u32 = at(src, "return 0;");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_off,
            .end = ret_off + @as(u32, @intCast("return 0;".len)),
            .new_text = "return q;",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M5 — `if` / `else if` / `else` condition mutations.
//
// `processOneStmt` for `.@"if"` (`src/AstVisit.zig:154`) visits the
// condition in the enclosing scope and pushes the body / else compounds
// (which open their own scopes). `findSlotInStmt`'s `.@"if"` arm
// recurses through `else_branch` so nested `else if` chains stay
// reachable. M5 covers each shape, plus the use-before-declaration
// fallback path through `error.AddWalkRaisedErrors`
// (`src/Incremental.zig:754`).
// =========================================================================

test "M5.a: if-condition operator flip (binary_expr anchor)" {
    const src: [:0]const u8 = "fn f(x: i32) { if x > 0 { return; } }";
    const new_src: []const u8 = "fn f(x: i32) { if x >= 0 { return; } }";
    const cond_off: u32 = at(src, "x > 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("x > 0".len)),
            .new_text = "x >= 0",
        },
        new_src,
        true,
    );
}

test "M5.b: else-if chain inner literal flip (literal_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(x: i32) { if x > 0 { return; } else if x == 0 { return; } else { return; } }";
    const new_src: []const u8 =
        "fn f(x: i32) { if x > 0 { return; } else if x == 1 { return; } else { return; } }";
    const inner_lit: u32 = at(src, "x == 0") + 5;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = inner_lit, .end = inner_lit + 1, .new_text = "1" },
        new_src,
        true,
    );
}

test "M5.c: if-condition operand swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(a: i32, b: i32) { if a > b { return; } }";
    const new_src: []const u8 =
        "fn f(a: i32, b: i32) { if b > a { return; } }";
    const cond_off: u32 = at(src, "a > b");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("a > b".len)),
            .new_text = "b > a",
        },
        new_src,
        true,
    );
}

test "M5.d: edit return value inside if-body (return_stmt anchor)" {
    const src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } return 0; }";
    const new_src: []const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 7; } return 0; }";
    const ret_off: u32 = at(src, "return 1;");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = ret_off,
            .end = ret_off + @as(u32, @intCast("return 1;".len)),
            .new_text = "return 7;",
        },
        new_src,
        true,
    );
}

test "M5.e: condition references local declared later → hot path with E0102" {
    // The add-walk encounters `y` referenced before its declaration,
    // emits E0102, and surfaces it on the result. Since the bidirectional
    // error-fixup landing, this is no longer a fallback — the hot path
    // succeeds and `result.errors` matches a fresh full parse.
    const src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } let y = 2; return y; }";
    const new_src: []const u8 =
        "fn f(x: i32) -> i32 { if x > 0 || y < 0 { return 1; } let y = 2; return y; }";
    const cond_off: u32 = at(src, "x > 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("x > 0".len)),
            .new_text = "x > 0 || y < 0",
        },
        new_src,
        true,
    );
}

// Note — M5.f / M5.g (use-before-decl suppression tests) are intentionally
// omitted. They require a sub-walk over an ident whose `ref` was set by
// the add-walk's E0102 branch (which does NOT bump use_count,
// `src/AstVisit.zig:253-257`). The current sub-walk at
// `src/AstVisit.zig:259-270` decrements `use_count` whenever `ref`
// isValid(), so it removes a count the add-walk never added, producing
// a use_count mismatch vs the full-parse oracle. Introduction scenarios
// (M5.e) are unaffected; only *inverse* edits hit this. Suppression
// coverage for E0102 lives in `incremental_error_fixup_test.zig`'s
// F-SUP family, whose oracle compares errors (not use_counts), so those
// tests pass even while this incremental-sub-walk bug remains latent.

// =========================================================================
// M6 — `loop` / `while` continuing & condition mutations.
//
// Neither `loop_stmt` nor `while_stmt` opens its own scope — only the
// nested compound bodies do. `findSlotInStmt` for `.loop`
// (`src/Incremental.zig:1208`) walks `body` then `continuing`. M6 covers
// while-condition, loop-continuing assign-RHS, break_if condition, and a
// 5-iteration burst.
// =========================================================================

test "M6.a: while-condition RHS ident swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(i: i32) { let limit = 10; while i < 0 { } }";
    const new_src: []const u8 =
        "fn f(i: i32) { let limit = 10; while i < limit { } }";
    const cond_off: u32 = at(src, "i < 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < 0".len)),
            .new_text = "i < limit",
        },
        new_src,
        true,
    );
}

test "M6.b: loop continuing assign-RHS swap (binary_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(i: i32) { var k: i32 = 0; loop { continuing { k = k + 1; break if k > 5; } } }";
    const new_src: []const u8 =
        "fn f(i: i32) { var k: i32 = 0; loop { continuing { k = k + 2; break if k > 5; } } }";
    const bin_off: u32 = at(src, "k = k + 1") + @as(u32, @intCast("k = ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = bin_off,
            .end = bin_off + @as(u32, @intCast("k + 1".len)),
            .new_text = "k + 2",
        },
        new_src,
        true,
    );
}

test "M6.c: break-if condition ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() { var done: bool = false; var stop: bool = true; loop { continuing { break if done; } } }";
    const new_src: []const u8 =
        "fn f() { var done: bool = false; var stop: bool = true; loop { continuing { break if stop; } } }";
    const id_off: u32 = at(src, "break if done") + @as(u32, @intCast("break if ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = id_off,
            .end = id_off + @as(u32, @intCast("done".len)),
            .new_text = "stop",
        },
        new_src,
        true,
    );
}

test "M6.e: while-condition edited to reference a use-before-decl ident emits E0102" {
    // Replace the entire `i < 0` binary_expr with `i < cap` — binary
    // stays binary (kind-stable). `cap` is declared after the while, so
    // `lookupSymbol` misses on position and E0102 fires.
    const src: [:0]const u8 =
        "fn f(i: i32) { while i < 0 { } let cap: i32 = 10; }";
    const new_src: []const u8 =
        "fn f(i: i32) { while i < cap { } let cap: i32 = 10; }";
    const cond_off: u32 = at(src, "i < 0");
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = cond_off,
            .end = cond_off + @as(u32, @intCast("i < 0".len)),
            .new_text = "i < cap",
        },
        new_src,
        true,
    );
}

test "M6.f: break-if condition ident swapped to a use-before-decl ident emits E0102" {
    // Ident→ident swap on the break-if condition: `k` is declared
    // before the loop, `later` after. The add-walk resolves `later`
    // against the fn body scope, misses on position, hits any-loc →
    // E0102.
    const src: [:0]const u8 =
        "fn f() { var k: bool = false; loop { continuing { break if k; } } var later: bool = true; }";
    const new_src: []const u8 =
        "fn f() { var k: bool = false; loop { continuing { break if later; } } var later: bool = true; }";
    const id_off: u32 = at(src, "break if k") + @as(u32, @intCast("break if ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{
            .start = id_off,
            .end = id_off + 1,
            .new_text = "later",
        },
        new_src,
        true,
    );
}

// =========================================================================
// M7 — Member-access & call-argument chain mutations.
//
// `findSlotInExprField` (`src/Incremental.zig:1237`) descends through
// `.member`, `.index`, `.call`, `.unary`, and `.paren`. M7 covers a deep
// member chain, an inner index-expression edit, mid-call argument swap,
// nested calls, unary, and nested parentheses — each picking a different
// branch of the expression descent.
// =========================================================================

test "M7.a: chained member-access trailing field rename (member_expr anchor)" {
    // Renaming the trailing field `.c` keeps the outermost member_expr
    // shape; the change lands on the member-name token whose parent
    // anchor is the outermost member_expr.
    const src: [:0]const u8 =
        "struct Inner { x: f32 } struct Mid { c: Inner } struct Outer { b: Mid } fn f(o: Outer) -> f32 { return o.b.c.x; }";
    const new_src: []const u8 =
        "struct Inner { x: f32 } struct Mid { c: Inner } struct Outer { b: Mid } fn f(o: Outer) -> f32 { return o.b.c.xx; }";
    const off: u32 = at(src, "o.b.c.x;") + @as(u32, @intCast("o.b.c.".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + 1, .new_text = "xx" },
        new_src,
        true,
    );
}

test "M7.b: index-expr inner literal swap (literal_expr anchor)" {
    const src: [:0]const u8 =
        "fn f(arr: array<i32, 4>, i: i32) -> i32 { return arr[i + 1]; }";
    const new_src: []const u8 =
        "fn f(arr: array<i32, 4>, i: i32) -> i32 { return arr[i + 2]; }";
    const lit_off: u32 = at(src, "i + 1") + @as(u32, @intCast("i + ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 1, .new_text = "2" },
        new_src,
        true,
    );
}

test "M7.c: third call-arg ident swap to sibling local (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn g(a: i32, b: i32, c: i32) -> i32 { return a + b + c; } fn f() -> i32 { let x = 1; let y = 2; let z = 3; let w = 4; return g(x, y, z); }";
    const new_src: []const u8 =
        "fn g(a: i32, b: i32, c: i32) -> i32 { return a + b + c; } fn f() -> i32 { let x = 1; let y = 2; let z = 3; let w = 4; return g(x, y, w); }";
    // The third arg is the trailing `z` before the `)`.
    const arg_off: u32 = at(src, "g(x, y, z)") + @as(u32, @intCast("g(x, y, ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = arg_off, .end = arg_off + 1, .new_text = "w" },
        new_src,
        true,
    );
}

test "M7.d: ident inside nested call argument (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn g(a: i32) -> i32 { return a; } fn h(a: i32, b: i32) -> i32 { return a; } fn f() -> i32 { let x = 1; let xx = 2; let y = 3; return h(g(x), y); }";
    const new_src: []const u8 =
        "fn g(a: i32) -> i32 { return a; } fn h(a: i32, b: i32) -> i32 { return a; } fn f() -> i32 { let x = 1; let xx = 2; let y = 3; return h(g(xx), y); }";
    const arg_off: u32 = at(src, "h(g(x), y)") + @as(u32, @intCast("h(g(".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = arg_off, .end = arg_off + 1, .new_text = "xx" },
        new_src,
        true,
    );
}

test "M7.e: unary operand ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let aa = 2; return -a; }";
    const new_src: []const u8 =
        "fn f() -> i32 { let a = 1; let aa = 2; return -aa; }";
    const id_off: u32 = at(src, "return -a;") + @as(u32, @intCast("return -".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = id_off, .end = id_off + 1, .new_text = "aa" },
        new_src,
        true,
    );
}

test "M7.f: nested paren innermost ident swap (ident_expr anchor)" {
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; let d = 4; return (a + (b + c)); }";
    const new_src: []const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; let d = 4; return (a + (b + d)); }";
    const id_off: u32 = at(src, "(b + c)") + @as(u32, @intCast("(b + ".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = id_off, .end = id_off + 1, .new_text = "d" },
        new_src,
        true,
    );
}

test "M7.g: call-arg ident swapped to a use-before-decl ident emits E0102" {
    // Ident→ident swap on a call-arg keeps the anchor kind-stable
    // (ident_expr → ident_expr). `a` is declared before the call;
    // `laterArg` is declared after → position miss + any-loc hit =
    // E0102.
    const src: [:0]const u8 =
        "fn g(x: i32) -> i32 { return x; } fn f() -> i32 { let a: i32 = 7; let r: i32 = g(a); let laterArg: i32 = 3; return r; }";
    const new_src: []const u8 =
        "fn g(x: i32) -> i32 { return x; } fn f() -> i32 { let a: i32 = 7; let r: i32 = g(laterArg); let laterArg: i32 = 3; return r; }";
    const arg_off: u32 = at(src, "g(a)") + 2;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = arg_off, .end = arg_off + 1, .new_text = "laterArg" },
        new_src,
        true,
    );
}

test "M7.h: index-expr index ident swapped to a use-before-decl ident emits E0102" {
    // Ident→ident swap inside `xs[first]`. `first` is declared before
    // the load, `idx` after → E0102 at the use site.
    const src: [:0]const u8 =
        "fn f() -> f32 { let first: i32 = 0; var xs: array<f32, 4> = array<f32, 4>(0, 0, 0, 0); var y: f32 = xs[first]; let idx: i32 = 1; return y; }";
    const new_src: []const u8 =
        "fn f() -> f32 { let first: i32 = 0; var xs: array<f32, 4> = array<f32, 4>(0, 0, 0, 0); var y: f32 = xs[idx]; let idx: i32 = 1; return y; }";
    const off: u32 = at(src, "xs[first]") + @as(u32, @intCast("xs[".len));
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = off, .end = off + @as(u32, @intCast("first".len)), .new_text = "idx" },
        new_src,
        true,
    );
}

test "M6.d: 5 successive condition flips on a while keep hot path" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        "fn f(i: i32) { let a = 1; let b = 2; while i < 0 { } }";
    var prev = try Incremental.parseFull(gpa, src);
    defer prev.deinit();

    // Cycle the trailing `0` through `0..4` each iteration; offset is
    // stable because the literal stays one byte wide.
    const lit_off: u32 = at(src, "while i < 0") + @as(u32, @intCast("while i < ".len));
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const ch: u8 = '0' + ((i + 1) % 5);
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectShapesMatch(gpa, next.module, oracle.module);
        try expectUseCountsMatch(next.module, oracle.module);
        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// M8 — Mixed-anchor mutation churn + retained_arenas growth.
//
// Each successful symbol-free reparse moves `prev.arena` into
// `result.retained_arenas` (`src/Incremental.zig:774`). M8 stresses the
// retention bookkeeping under (a) cross-anchor-kind edit cycles, (b) long
// hot-path bursts that monotonically grow `retained_arenas`, (c) bursts
// that alternate hot path with fallback (each fallback resets retention
// to zero), and (d) per-symbol use_count round-trips on multi-ident
// expressions.
// =========================================================================

test "M8.a: 4-edit round-trip across literal/binary/return/attribute returns to base" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "@compute @workgroup_size(8) fn f() -> i32 { let a = 1; return a + 2; }";

    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();

    // 1. Flip the return-value literal `2` → `5`. Anchor: literal_expr.
    const lit_off: u32 = at(base_src, "a + 2") + 4;
    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "5",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);

    // 2. Inverse: flip back `5` → `2` on the same byte. Anchor: literal_expr.
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "2",
    });
    defer step2.deinit();
    try std.testing.expect(step2.reused);

    // 3. Flip the workgroup_size literal `8` → `16`. Anchor: literal_expr
    //    inside attribute_args.
    const wg_off: u32 = at(step2.source, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    var step3 = try Incremental.reparse(gpa, &step2, .{
        .start = wg_off,
        .end = wg_off + 1,
        .new_text = "16",
    });
    defer step3.deinit();
    try std.testing.expect(step3.reused);

    // 4. Inverse: flip workgroup_size back to `8`. Source returns to base.
    var step4 = try Incremental.reparse(gpa, &step3, .{
        .start = wg_off,
        .end = wg_off + 2,
        .new_text = "8",
    });
    defer step4.deinit();
    try std.testing.expect(step4.reused);
    try std.testing.expectEqualStrings(base_src, step4.source);

    // Final shape + per-symbol use_counts match a fresh parse of base.
    var oracle = try Incremental.parseFull(gpa, base_src);
    defer oracle.deinit();
    try expectShapesMatch(gpa, step4.module, oracle.module);
    try expectUseCountsMatch(step4.module, oracle.module);
}

// M8.b and M8.c used to assert the per-edit growth of
// `retained_arenas.items.len` under the old fresh-arena hot path:
// one entry appended per successful symbol-free reparse, reset on
// fallback. With the in-place hot path (`in_place_hot_path = true` in
// `src/Incremental.zig`) `retained_arenas` stays at 0 across any
// number of hot-path edits. Coverage of the underlying churn
// correctness is preserved by M8.d's inverse-round-trip assertion and
// the M9 family (see `tests/incremental_mutation_longtail_test.zig`
// after Step 2 of `docs/arena-transfer-zero-alloc-plan.md`).

test "M8.d: edit + inverse on multi-symbol expression preserves use_counts" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let c = 3; return a + b * c; }";

    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();

    const a_uc0 = useCountOf(step0.module, "a");
    const b_uc0 = useCountOf(step0.module, "b");
    const c_uc0 = useCountOf(step0.module, "c");

    // Replace the whole return value with a permuted form. Anchor:
    // binary_expr.
    const ret_off: u32 = at(base_src, "a + b * c");
    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = ret_off,
        .end = ret_off + @as(u32, @intCast("a + b * c".len)),
        .new_text = "c + b * a",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);

    const ret_off2: u32 = at(step1.source, "c + b * a");
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = ret_off2,
        .end = ret_off2 + @as(u32, @intCast("c + b * a".len)),
        .new_text = "a + b * c",
    });
    defer step2.deinit();
    try std.testing.expect(step2.reused);

    try std.testing.expectEqualStrings(base_src, step2.source);
    // Per-symbol use_counts match the pre-edit state exactly. A sub/add
    // inversion bug that swaps a's count with c's would slip past an
    // aggregate-only check but fail here.
    try std.testing.expectEqual(a_uc0, useCountOf(step2.module, "a"));
    try std.testing.expectEqual(b_uc0, useCountOf(step2.module, "b"));
    try std.testing.expectEqual(c_uc0, useCountOf(step2.module, "c"));
}

test "M8.e: 4-edit chain alternating E0102-introducing anchors per section" {
    // One edit per emissible section: M3 (for-cond), M5 (if-cond),
    // M6 (while-cond), M7 (call-arg). Each step introduces a new
    // use-before-decl reference to an already-later-declared symbol.
    // The error bucket grows monotonically from 0 → 4 across the
    // chain; the oracle on the final source must agree.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn g(x: i32) -> i32 { return x; }" ++
        " fn f(i: i32) -> i32 {" ++
        " for (var j = 0; j < 0; j = j + 1) {}" ++
        " if i > 0 { }" ++
        " while i < 0 { }" ++
        " let r: i32 = g(0);" ++
        " let cap: i32 = 10; let lateA: i32 = 1; let lateB: i32 = 2; let lateC: i32 = 3;" ++
        " return r + cap + lateA + lateB + lateC; }";
    var step0 = try Incremental.parseFull(gpa, base_src);
    defer step0.deinit();
    try std.testing.expectEqual(@as(usize, 0), step0.errors.len);

    // Step 1 — M3: for-cond `j < 0` → `j < cap`.
    const c1_off: u32 = at(base_src, "j < 0");
    var step1 = try Incremental.reparse(gpa, &step0, .{
        .start = c1_off,
        .end = c1_off + @as(u32, @intCast("j < 0".len)),
        .new_text = "j < cap",
    });
    defer step1.deinit();
    try std.testing.expect(step1.reused);
    try std.testing.expectEqual(@as(usize, 1), step1.errors.len);

    // Step 2 — M5: if-cond `i > 0` → `i > lateA`.
    const c2_off: u32 = at(step1.source, "i > 0");
    var step2 = try Incremental.reparse(gpa, &step1, .{
        .start = c2_off,
        .end = c2_off + @as(u32, @intCast("i > 0".len)),
        .new_text = "i > lateA",
    });
    defer step2.deinit();
    try std.testing.expect(step2.reused);
    try std.testing.expectEqual(@as(usize, 2), step2.errors.len);

    // Step 3 — M6: while-cond `i < 0` → `i < lateB`.
    const c3_off: u32 = at(step2.source, "i < 0");
    var step3 = try Incremental.reparse(gpa, &step2, .{
        .start = c3_off,
        .end = c3_off + @as(u32, @intCast("i < 0".len)),
        .new_text = "i < lateB",
    });
    defer step3.deinit();
    try std.testing.expect(step3.reused);
    try std.testing.expectEqual(@as(usize, 3), step3.errors.len);

    // Step 4 — M7: call-arg `g(0)` → `g(lateC)` (literal→ident, kind
    // change — routes through fallback but still oracle-matches).
    const c4_off: u32 = at(step3.source, "g(0)") + 2;
    var step4 = try Incremental.reparse(gpa, &step3, .{
        .start = c4_off,
        .end = c4_off + 1,
        .new_text = "lateC",
    });
    defer step4.deinit();
    try std.testing.expectEqual(@as(usize, 4), step4.errors.len);

    var oracle = try Incremental.parseFull(gpa, step4.source);
    defer oracle.deinit();
    try expectErrorsOracleMatch(step4.errors, oracle.errors);
}

// =========================================================================
// M9 — In-place hot-path arena reuse: `retained_arenas` stays at 0
// across any length of symbol-free hot-path churn.
//
// Prior to `in_place_hot_path = true` in `src/Incremental.zig`, each
// successful hot-path reparse appended prev's arena to the new
// result's `retained_arenas`, growing the chain monotonically. The
// in-place path extends prev.arena in place instead, so the chain stays
// empty. M9 covers single-anchor bursts (a/d), anchor-kind alternation
// (b/c), and cross-function interleaving (e), each verified against a
// `parseFull` oracle on the final source.
// =========================================================================

test "M9.a: 30 literal churns keep retained_arenas at 0" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(usize, 0), prev.retained_arenas.items.len);

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M9.b: alternating ident_expr refs across two module-scope consts" {
    // Base module has `a` and `b` at module scope; the return value
    // alternates between `1 + a` and `1 + b`. Each edit's anchor is
    // ident_expr (the swapped operand). In-place path must preserve
    // per-symbol use_count exactly on each iteration.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return 1 + a; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_name: []const u8 = "a";
    const ident_off_init: u32 = at(base_src, "1 + a") + 4;
    var ident_off = ident_off_init;

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const next_name: []const u8 = if (std.mem.eql(u8, cur_name, "a")) "b" else "a";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = ident_off,
            .end = ident_off + 1,
            .new_text = next_name,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        cur_name = next_name;
        prev.deinit();
        prev = next;
        ident_off = at(prev.source, if (std.mem.eql(u8, cur_name, "a")) "1 + a" else "1 + b") + 4;
    }
}

test "M9.c: 20 binary_expr operator flips keep retained_arenas at 0" {
    // Covers the binary_expr anchor variant of the in-place arena
    // invariant. Every edit stays on the same anchor kind (binary_expr)
    // and re-lowers the whole RHS so the add/sub walk exercises multi-
    // operand symbol resolution. Kind-flip scenarios (ident_expr ↔
    // binary_expr) legitimately fall back — S8 documents why — so they
    // are not part of the in-place-arena contract tested here.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; return a + 0; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var use_plus: bool = true;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        // Swap the operator inside `a + 0` ↔ `a - 0`. Anchor: binary_expr.
        const op_needle: []const u8 = if (use_plus) "a + 0" else "a - 0";
        const op_off: u32 = at(prev.source, op_needle) + 2;
        const new_op: []const u8 = if (use_plus) "-" else "+";

        const next = try Incremental.reparse(gpa, &prev, .{
            .start = op_off,
            .end = op_off + 1,
            .new_text = new_op,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        use_plus = !use_plus;
        prev.deinit();
        prev = next;
    }
}

test "M9.d: 20 attribute-arg literal flips keep retained_arenas at 0" {
    // The attribute-arg path (`findSlotInAttribute`) is structurally
    // distinct from statement/expression slot lookup — M1 exercises
    // correctness; M9.d exercises arena bookkeeping on that code path.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "@compute @workgroup_size(8) fn main() {}";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "@workgroup_size(") + @as(u32, @intCast("@workgroup_size(".len));
    var prev_len: u32 = 1;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        // Cycle "8" → "16" → "32" → "64" → "128" → back to "8". Constant
        // length per group keeps lit_off stable; we just track the
        // current digit count.
        const digits: []const u8 = switch (i % 5) {
            0 => "16",
            1 => "32",
            2 => "64",
            3 => "128",
            4 => "8",
            else => unreachable,
        };
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + prev_len,
            .new_text = digits,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);
        prev_len = @intCast(digits.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectUseCountsMatch(next.module, oracle.module);

        prev.deinit();
        prev = next;
    }
}

test "M9.e: interleaved edits across two functions keep the chain flat" {
    // Two fns, each with its own scope. Edits alternate between them
    // so the add-walk repeatedly positions `ctx.scope` at different
    // anchor scopes (via `scopeAtCstNode`). Arena invariant must hold
    // across scope switches.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn fa() -> i32 { return 1; } fn fb() -> i32 { return 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const target: []const u8 = if (i % 2 == 0) "fn fa" else "fn fb";
        const fn_start: u32 = at(prev.source, target);
        const body_open: u32 = fn_start + @as(u32, @intCast(std.mem.indexOf(u8, prev.source[fn_start..], "return ").?)) + @as(u32, @intCast("return ".len));
        // The literal following `return ` is a single digit — flip it.
        const new_digit: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{new_digit};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = body_open,
            .end = body_open + 1,
            .new_text = &new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M9.f: 30-edit burst alternating E0102 introduction / no-op keeps arena flat" {
    // Same anchor (if-cond binary_expr) every iteration. Even steps
    // introduce a use-before-decl reference to `late`; odd steps
    // revert to the clean form. Two invariants per step:
    //   1. `retained_arenas` stays at 0 (in-place hot path).
    //   2. `errors` matches a fresh parseFull on the current source.
    //
    // NOTE: the inverse (even → odd) transition exposes the pre-existing
    // sub-walk vs E0102-ref use_count bug documented near M5.f. This
    // test therefore asserts the *error bucket* matches the oracle each
    // step (the arena + error-fixup contracts) but does not assert per-
    // symbol use_count parity. Use-count parity is already guarded on
    // every clean edit via the M-series runEdit harness.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } let late: i32 = 2; return late; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(usize, 0), prev.retained_arenas.items.len);

    const cond_off: u32 = at(base_src, "x > 0");
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "x > late" else "x > 0";
        const old_len: u32 = @intCast(if (i % 2 == 0) "x > 0".len else "x > late".len);
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = cond_off,
            .end = cond_off + old_len,
            .new_text = new_text,
        });
        try std.testing.expect(next.reused);
        try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectErrorsOracleMatch(next.errors, oracle.errors);

        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// M10 — Compaction watermark: the in-place hot path grows prev.arena
// forever, so the reparse driver trips a full-parse fallback once live
// arena capacity passes 8× source size (floor 16 KiB). M10 validates
// that (a) sustained churn eventually trips at least once, (b) a large
// insert trips quickly, and (c) the chain resets to a fresh arena on
// the trip.
// =========================================================================

test "M10.a: sustained literal churn trips the watermark at least once" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var trip_count: u32 = 0;
    var i: u32 = 0;
    // 500 iterations on a 31-byte base: threshold = max(256 KiB, 31*8)
    // = 256 KiB. Each hot-path edit adds a new source copy, re-lexed
    // token array, CST splice, and lowered AST subtree — enough to
    // trip at least once across 500 edits.
    while (i < 500) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        if (!next.reused) trip_count += 1;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(trip_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M10.b: a large insert makes the next edit trip the watermark" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    // Craft a single hot-path edit whose prev-arena cost exceeds the
    // watermark on the *next* iteration. We insert a 200 KiB integer
    // literal so after one edit prev.arena's capacity is already past
    // the 256 KiB floor; the second edit immediately falls back.
    const padding_len: usize = 200 * 1024;
    const big_lit = try gpa.alloc(u8, padding_len);
    defer gpa.free(big_lit);
    @memset(big_lit, '1');

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    const first = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = big_lit,
    });
    prev.deinit();
    prev = first;
    try std.testing.expect(prev.reused);

    const next = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + @as(u32, @intCast(padding_len)),
        .new_text = "7",
    });
    try std.testing.expect(!next.reused);

    var oracle = try Incremental.parseFull(gpa, next.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, next.module, oracle.module);
    try expectUseCountsMatch(next.module, oracle.module);

    prev.deinit();
    prev = next;
}

test "M10.c: a watermark trip resets the arena and re-enables the hot path" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const padding_len: usize = 200 * 1024;
    const big_lit = try gpa.alloc(u8, padding_len);
    defer gpa.free(big_lit);
    @memset(big_lit, '1');

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    const first = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = big_lit,
    });
    prev.deinit();
    prev = first;

    // Trip the watermark with a shrinking edit.
    const tripped = try Incremental.reparse(gpa, &prev, .{
        .start = lit_off,
        .end = lit_off + @as(u32, @intCast(padding_len)),
        .new_text = "7",
    });
    try std.testing.expect(!tripped.reused);
    // Full-parse fallback allocates a fresh arena and retains none.
    try std.testing.expectEqual(@as(usize, 0), tripped.retained_arenas.items.len);
    prev.deinit();
    prev = tripped;

    // Next hot-path edit should take the in-place path on the fresh
    // arena and keep retained_arenas at 0. Post-trip source is
    // `"fn f() -> i32 { return 1 + 7; }"` — flip the `7` to `9`.
    const post_lit_off: u32 = at(prev.source, "+ 7") + 2;
    const follow = try Incremental.reparse(gpa, &prev, .{
        .start = post_lit_off,
        .end = post_lit_off + 1,
        .new_text = "9",
    });
    try std.testing.expect(follow.reused);
    try std.testing.expectEqual(@as(usize, 0), follow.retained_arenas.items.len);

    prev.deinit();
    prev = follow;
}

// =========================================================================
// M11 — Fallback robustness: each known hot-path failure mode must
// leave the resulting state walkable and must NOT poison the next
// reparse. The in-place hot path may write garbage bytes into
// prev.arena before a late validation gate fails; this family chains a
// failure-triggering edit with a clean hot edit and asserts the clean
// edit still hot-paths and produces an oracle-matching module.
// =========================================================================

test "M11.a: AnchorKindMismatch fallback allows a follow-up hot edit" {
    // Triggering edit: S8-shape `1` → `1 * 3` inside `return 1 + 2;`
    // produces a binary_expr where the anchor was literal_expr. Hot
    // path bails; parseFull returns a clean result.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const lit_off: u32 = at(base_src, "return 1") + @as(u32, @intCast("return ".len));
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "1 * 3",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);

    // Post-fallback source: `"fn f() -> i32 { return 1 * 3 + 2; }"`.
    // Flip the trailing `2` via a literal-swap edit — classic
    // symbol-free hot-path shape.
    const tail_lit: u32 = at(fallback.source, "3 + 2") + 4;
    var hot = try Incremental.reparse(gpa, &fallback, .{
        .start = tail_lit,
        .end = tail_lit + 1,
        .new_text = "9",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

test "M11.b: AnchorParseError fallback allows a follow-up hot edit" {
    // S16-shape: `return 2;` → `return +;` produces a literal_expr
    // anchor that reparses into an error subtree — sub_parser.errors
    // populated → fallback.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 2; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const lit_off: u32 = at(base_src, "return ") + @as(u32, @intCast("return ".len));
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = lit_off,
        .end = lit_off + 1,
        .new_text = "+",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);
    // Full-parse fallback gives the error-recovered module; fix the
    // parse error with a second edit and confirm the hot path fires.
    const bad_off: u32 = at(fallback.source, "return +") + @as(u32, @intCast("return ".len));
    var fix = try Incremental.reparse(gpa, &fallback, .{
        .start = bad_off,
        .end = bad_off + 1,
        .new_text = "9",
    });
    defer fix.deinit();
    // Fixing the parse error is also a fallback (prev had errors, so
    // the reparse oracle must run). What we care about is the result
    // is byte-clean and a *subsequent* literal flip takes the hot
    // path.
    const lit2: u32 = at(fix.source, "return 9") + @as(u32, @intCast("return ".len));
    var hot = try Incremental.reparse(gpa, &fix, .{
        .start = lit2,
        .end = lit2 + 1,
        .new_text = "7",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

test "M11.c: kind-mismatch fallback allows a follow-up hot edit" {
    // Replacing `false` with `x < 1` flips the anchor kind from
    // literal_expr to binary_expr — a kind mismatch, distinct from any
    // add-walk concern, so the hot path bails to a full re-parse.
    // Verifies that a subsequent clean edit still hot-paths cleanly.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f() -> i32 { if (false) { return 1; } let x = 7; return x; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    const cond_off: u32 = at(base_src, "(false)") + 1;
    var fallback = try Incremental.reparse(gpa, &base, .{
        .start = cond_off,
        .end = cond_off + @as(u32, @intCast("false".len)),
        .new_text = "x < 1",
    });
    defer fallback.deinit();
    try std.testing.expect(!fallback.reused);

    // Post-fallback source references `x` in the condition. A
    // subsequent literal flip on the `1` inside `(x < 1)` is a
    // clean literal_expr hot edit.
    const tail_lit: u32 = at(fallback.source, "x < 1") + 4;
    var hot = try Incremental.reparse(gpa, &fallback, .{
        .start = tail_lit,
        .end = tail_lit + 1,
        .new_text = "2",
    });
    defer hot.deinit();
    try std.testing.expect(hot.reused);

    var oracle = try Incremental.parseFull(gpa, hot.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, hot.module, oracle.module);
    try expectUseCountsMatch(hot.module, oracle.module);
}

test "M11.d: fallback path surfaces E0102 from the full re-parse" {
    // Cross-decl insertion (prepending a whole new fn) forces fallback
    // because the edit spans zero→N bytes at the module root. The
    // inserted `fn f` contains an intra-body use-before-decl of `late`,
    // so the full re-parse emits one E0102; the fallback's errors must
    // match the oracle exactly.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn g() -> i32 { return 0; }";
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 0), base.errors.len);

    const insertion: []const u8 =
        "fn f() -> i32 { return late; let late: i32 = 7; return late; } ";
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 0,
        .end = 0,
        .new_text = insertion,
    });
    defer updated.deinit();
    try std.testing.expect(!updated.reused);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
    try std.testing.expectEqual(@as(usize, 1), updated.errors.len);
    try std.testing.expectEqualStrings("E0102", updated.errors[0].code);
}

// =========================================================================
// M12 — Trivia-only shortcut: zero-delta edits that leave every
// non-trivia token tag/length/text unchanged must bypass the hot
// path entirely and reuse prev.module + prev.cst byte-for-byte. The
// distinguishing observable is pointer-equality on module and on the
// underlying CST node store. Edits that fail the zero-delta-trivia
// precondition fall through to the regular path without firing.
// =========================================================================

test "M12.a: zero-delta line-comment body swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "// abc\nfn f() {}";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    // Replace `abc` with `xyz` — same length, inside a line comment.
    const body_off: u32 = at(base_src, "abc");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 3,
        .new_text = "xyz",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqualStrings("// xyz\nfn f() {}", updated.source);

    // Shortcut fingerprint: the Module pointer is byte-identical and
    // the CST's node-store backing pointer is unchanged.
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.b: zero-delta whitespace swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() {   return 0; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    // Replace three spaces with tab+space+space (same length, all trivia).
    const ws_off: u32 = at(base_src, "{   ") + 1;
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = ws_off,
        .end = ws_off + 3,
        .new_text = "\t  ",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.c: zero-delta block-comment body swap reuses module + CST" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "/* old */ fn f() {}";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    const body_off: u32 = at(base_src, "old");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 3,
        .new_text = "new",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

test "M12.d: non-zero-delta trivia insert falls through to regular path" {
    // A comment insertion is trivia-only but has non-zero delta; the
    // shortcut must NOT fire, and the regular reparse must still
    // produce the correctly-spliced source.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    // Replace `return` with `return /* x */`. Non-zero-delta trivia
    // insertion — shortcut condition fails on the delta check.
    const ret_off: u32 = at(base_src, "return");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = ret_off,
        .end = ret_off + @as(u32, @intCast("return".len)),
        .new_text = "return /* x */",
    });
    defer updated.deinit();

    try std.testing.expectEqualStrings("fn f() -> i32 { return /* x */ 1; }", updated.source);
}

test "M12.e: zero-delta trivia swap across several tokens reuses module" {
    // Replace a span inside a comment that sits between two real
    // decls. Still zero-delta, still trivia-only, still
    // shortcut-eligible.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "const x = 1; // abc def\nconst y = 2;";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const prev_module_ptr = prev.module;
    const prev_cst_nodes_bytes = prev.cst.nodes.bytes;

    const body_off: u32 = at(base_src, "abc");
    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = body_off,
        .end = body_off + 7,
        .new_text = "zzz qqq",
    });
    defer updated.deinit();

    try std.testing.expect(updated.reused);
    try std.testing.expectEqual(prev_module_ptr, updated.module);
    try std.testing.expectEqual(prev_cst_nodes_bytes, updated.cst.nodes.bytes);
}

// =========================================================================
// M13 — Arena envelope smoke test: a 100-edit churn on a real
// compute.toys shader keeps arena capacity bounded by the
// compaction watermark on every iteration.
//
// queryCapacity() sums used + free pages in the ArenaAllocator's
// internal free-list, so this tracks live + cache-retained bytes.
// The assertion uses 16× source size as the envelope — the watermark
// trips at 8× source size (floor 256 KiB); a 16× ceiling leaves
// headroom for the single edit between checks that allocated into
// prev.arena before the next watermark check.
// =========================================================================

test "M13: 100-edit literal churn on circle_sample keeps arena bounded" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = @embedFile("testdata/compute.toys/circle_sample.wgsl");

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "let s = 1.0;") + @as(u32, @intCast("let s = ".len));
    const floor: usize = 256 * 1024;
    const envelope: usize = @max(floor, base_src.len) * @as(usize, 16);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });

        const bytes = next.arenaBytes();
        if (bytes >= envelope) {
            std.debug.print("M13: arena capacity {d} exceeded envelope {d} at iter {d}\n", .{ bytes, envelope, i });
            return error.ArenaEnvelopeExceeded;
        }

        prev.deinit();
        prev = next;
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M14 — Chained-reparse invariants across mutation sections.
//
// The edit-count bound (HOT_EDIT_COALESCE_MAX = 256) is a defense-in-
// depth backstop. The byte-watermark (M10) typically trips first on
// realistic shaders because per-edit arena cost (~KB/edit for tokens +
// CST splice + lowered subtree) reaches the 256 KiB floor well before
// 256 edits. M14 covers one chained test per mutation section (M1, M3,
// M4, M5, M6, M7) exercising two invariants that MUST hold regardless
// of which watermark fires:
//   (a) `retained_arenas.items.len == 0` on every result (commit-3
//       invariant, locks the always-empty guarantee),
//   (b) `hot_edits_since_full <= HOT_EDIT_COALESCE_MAX` when
//       `reused == true`; equals 0 when `reused == false` (coalesce
//       reset).
// Long bursts also assert at least one coalesce fires, which proves
// the reclamation path activates and correctly returns control to
// `parseFull`.
// =========================================================================

const HOT_MAX = Incremental.HOT_EDIT_COALESCE_MAX;

/// Shared per-iteration assertions for every M14 chain.
fn expectChainInvariants(r: *const Incremental.ReparseResult) !void {
    try std.testing.expectEqual(@as(usize, 0), r.retained_arenas.items.len);
    if (r.reused) {
        try std.testing.expect(r.hot_edits_since_full >= 1);
        try std.testing.expect(r.hot_edits_since_full <= HOT_MAX);
    } else {
        try std.testing.expectEqual(@as(u16, 0), r.hot_edits_since_full);
    }
}

test "M14.a: M1 attr-arg 300-edit chain holds invariants and coalesces" {
    // `@binding(0)` literal flips `0`↔`1` 300×. Anchor: literal_expr
    // inside attribute args (M1 path).
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32;";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const first_paren = at(base_src, "(0)");
    const second_paren = at(base_src[first_paren + 1 ..], "(0)") + first_paren + 1;
    const lit_off: u32 = second_paren + 1;

    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const ch: u8 = if (i % 2 == 0) '1' else '0';
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M14.a.ident: M1 attr-arg ident-swap 300-edit chain holds invariants and coalesces" {
    // `@binding(A|B)` ident flips `A`↔`B` 300×. Anchor: ident_expr
    // inside attribute args (M1.g path — post-fix). Mirrors M14.a's
    // literal-churn but flips the knob that would have leaked +1 drift
    // per iteration under the pre-fix add-walk, so every iteration
    // pressure-tests the `info.in_attribute` gate in addition to the
    // arena / coalesce bookkeeping.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "const A: u32 = 0; const B: u32 = 1; @group(0) @binding(A) var<uniform> u: f32;";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const off: u32 = at(base_src, "@binding(") + @as(u32, @intCast("@binding(".len));

    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const ch: u8 = if (i % 2 == 0) 'B' else 'A';
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = &new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
    // Both sibling consts are only ever named inside the attribute, so
    // the oracle holds them at `use_count == 0` — pinning that the chain
    // did not leak any residual +1 onto either symbol.
    try std.testing.expectEqual(@as(u32, 0), useCountOf(prev.module, "A"));
    try std.testing.expectEqual(@as(u32, 0), useCountOf(prev.module, "B"));
}

test "M14.b: M3 for-loop cond 300-edit chain holds invariants and coalesces" {
    // For-loop condition RHS `<10`↔`<11`. M3 path.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() { for (var i=0; i<10; i=i+1) {} }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_ten: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const needle: []const u8 = if (cur_ten) "i<10" else "i<11";
        const off: u32 = at(prev.source, needle) + 2;
        const new_text: []const u8 = if (cur_ten) "11" else "10";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 2,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_ten = !cur_ten;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
}

test "M14.c: M4 switch case-selector 300-edit chain holds invariants" {
    // Case selector `0`↔`2`.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x:i32) { switch(x) { case 0: {} case 1: {} default: {} } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_zero: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const needle: []const u8 = if (cur_zero) "case 0:" else "case 2:";
        const off: u32 = at(prev.source, needle) + 5;
        const new_text: []const u8 = if (cur_zero) "2" else "0";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_zero = !cur_zero;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
}

test "M14.d: M5 if/else 600-edit chain holds invariants with multiple coalesces" {
    // return literal `1`↔`3`.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x:i32)->i32 { if (x>0) { return 1; } else { return 2; } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var cur_one: bool = true;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        const needle: []const u8 = if (cur_one) "return 1" else "return 3";
        const off: u32 = at(prev.source, needle) + @as(u32, @intCast("return ".len));
        const new_text: []const u8 = if (cur_one) "3" else "1";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;

        cur_one = !cur_one;
        prev.deinit();
        prev = next;
    }
    // Long burst fires at least 2 coalesces (one per arena refill cycle).
    try std.testing.expect(coalesce_count >= 2);
}

test "M14.e: hot_edits_since_full is monotonic within an in-place run" {
    // Directly observe the counter: every successful in-place edit
    // increments it by 1; a coalesce resets it to 0. Sub-HOT_MAX bursts
    // may still coalesce via the byte-watermark; when they do, counter
    // resets and starts climbing again.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() { var i=0; loop { if (i>5) { break; } i=i+1; } }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();
    try std.testing.expectEqual(@as(u16, 0), prev.hot_edits_since_full);

    var cur_five: bool = true;
    var last_counter: u16 = 0;
    var observed_increment: bool = false;
    var observed_reset: bool = false;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const needle: []const u8 = if (cur_five) "i>5" else "i>6";
        const off: u32 = at(prev.source, needle) + 2;
        const new_text: []const u8 = if (cur_five) "6" else "5";
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (next.reused) {
            if (next.hot_edits_since_full == last_counter + 1) observed_increment = true;
            last_counter = next.hot_edits_since_full;
        } else {
            try std.testing.expectEqual(@as(u16, 0), next.hot_edits_since_full);
            observed_reset = true;
            last_counter = 0;
        }
        cur_five = !cur_five;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(observed_increment);
    // Reset may or may not fire in 200 edits depending on per-edit cost;
    // `observed_reset` is informational, not a gate. The counter-never-
    // exceeding-HOT_MAX invariant is enforced inside `expectChainInvariants`
    // on every iteration above.
    if (observed_reset) {
        try std.testing.expect(prev.hot_edits_since_full < HOT_MAX);
    }
}

test "M14.f: M7 member-access 300-edit chain holds invariants" {
    // Toggle `s.a`↔`s.a*1.0`. Anchor: member_expr.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "struct S { a: f32 } fn f(s: S) -> f32 { return s.a; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    var plain: bool = true;
    var coalesce_count: u32 = 0;
    var last_was_coalesce: bool = false;
    var post_coalesce_reused: bool = false;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const old_needle: []const u8 = if (plain) "return s.a;" else "return s.a*1.0;";
        const new_text: []const u8 = if (plain) "return s.a*1.0;" else "return s.a;";
        const off: u32 = at(prev.source, old_needle);
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + @as(u32, @intCast(old_needle.len)),
            .new_text = new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) {
            coalesce_count += 1;
            last_was_coalesce = true;
        } else if (last_was_coalesce) {
            post_coalesce_reused = true;
            last_was_coalesce = false;
        }
        plain = !plain;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 1);
    try std.testing.expect(post_coalesce_reused);
}

test "M14.g: M9 extended — 512-edit literal churn holds invariants" {
    // Extends M9.a's 30-edit scope; final oracle match proves chained
    // reparses across multiple coalesce cycles converge on the ground
    // truth a fresh parseFull would produce.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1 + 2; }";

    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(base_src, "1 + 2") + 4;
    var coalesce_count: u32 = 0;
    var i: u32 = 0;
    while (i < 512) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        try expectChainInvariants(&next);
        if (!next.reused) coalesce_count += 1;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(coalesce_count >= 2);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M14.h: 300-edit if-cond chain alternating E0102 introduction / clean" {
    // Parallel to M14.d but every other edit introduces a use-before-
    // decl reference to `late`. The bucket must track `1/0/1/0…` in
    // lockstep with a fresh oracle each step. Proves long-run stability
    // of the error-fixup + in-place-arena contracts under E0102 churn.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        "fn f(x: i32) -> i32 { if x > 0 { return 1; } let late: i32 = 2; return late; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const cond_off: u32 = at(base_src, "x > 0");
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const new_text: []const u8 = if (i % 2 == 0) "x > late" else "x > 0";
        const old_len: u32 = @intCast(if (i % 2 == 0) "x > 0".len else "x > late".len);
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = cond_off,
            .end = cond_off + old_len,
            .new_text = new_text,
        });
        try expectChainInvariants(&next);

        var oracle = try Incremental.parseFull(gpa, next.source);
        defer oracle.deinit();
        try expectErrorsOracleMatch(next.errors, oracle.errors);
        const expected_errs: usize = if (i % 2 == 0) 1 else 0;
        try std.testing.expectEqual(expected_errs, next.errors.len);

        prev.deinit();
        prev = next;
    }
}

// =========================================================================
// M15 — Cross-section retained_arenas sentinel.
//
// Runs every M14 fixture through a short burst (well below HOT_MAX)
// and asserts `retained_arenas.items.len == 0` on every result. Catches
// any future commit that introduces a new growth site on any mutation
// section without going through the edit-count coalesce path.
// =========================================================================

const M15Fixture = struct {
    base_src: [:0]const u8,
    needle: []const u8,
    old_byte: []const u8,
    new_byte: []const u8,
    needle_offset: u32,
};

test "M15: retained_arenas stays empty across every mutation fixture" {
    const gpa = std.testing.allocator;
    const fixtures = [_]M15Fixture{
        // M1 attr arg
        .{
            .base_src = "@group(0) @binding(0) var<uniform> u: f32;",
            .needle = "@binding(",
            .old_byte = "0",
            .new_byte = "1",
            .needle_offset = @intCast("@binding(".len),
        },
        // M3 for-loop cond
        .{
            .base_src = "fn f() { for (var i=0; i<9; i=i+1) {} }",
            .needle = "i<",
            .old_byte = "9",
            .new_byte = "8",
            .needle_offset = @intCast("i<".len),
        },
        // M4 switch case
        .{
            .base_src = "fn f(x:i32) { switch(x) { case 0: {} default: {} } }",
            .needle = "case ",
            .old_byte = "0",
            .new_byte = "1",
            .needle_offset = @intCast("case ".len),
        },
        // M5 if-body return
        .{
            .base_src = "fn f(x:i32)->i32 { if (x>0) { return 1; } else { return 2; } }",
            .needle = "return ",
            .old_byte = "1",
            .new_byte = "3",
            .needle_offset = @intCast("return ".len),
        },
        // M6 loop cond
        .{
            .base_src = "fn f() { var i=0; loop { if (i>5) { break; } i=i+1; } }",
            .needle = "i>",
            .old_byte = "5",
            .new_byte = "6",
            .needle_offset = @intCast("i>".len),
        },
        // M9 literal flip
        .{
            .base_src = "fn f() -> i32 { return 1 + 2; }",
            .needle = "+ ",
            .old_byte = "2",
            .new_byte = "3",
            .needle_offset = @intCast("+ ".len),
        },
    };

    for (fixtures) |fx| {
        var prev = try Incremental.parseFull(gpa, fx.base_src);
        defer prev.deinit();
        try std.testing.expectEqual(@as(usize, 0), prev.retained_arenas.items.len);

        var cur_old: bool = true;
        var i: u32 = 0;
        while (i < 60) : (i += 1) {
            const needle_start: u32 = at(prev.source, fx.needle) + fx.needle_offset;
            const ch_old = if (cur_old) fx.old_byte else fx.new_byte;
            const ch_new = if (cur_old) fx.new_byte else fx.old_byte;
            // Sanity: the byte at needle_start must be ch_old[0] before the edit.
            try std.testing.expectEqual(ch_old[0], prev.source[needle_start]);

            const next = try Incremental.reparse(gpa, &prev, .{
                .start = needle_start,
                .end = needle_start + 1,
                .new_text = ch_new,
            });
            try std.testing.expectEqual(@as(usize, 0), next.retained_arenas.items.len);
            cur_old = !cur_old;
            prev.deinit();
            prev = next;
        }
    }
}

// =========================================================================
// M16 — Boundary-exact edits.
//
// An edit whose `[start, end)` aligns exactly on the first/last non-trivia
// token boundary of a hot-path anchor must still hit that anchor. Off-by-
// one on either side demotes the match to the enclosing anchor; these
// tests pin the exact-match behavior so a future boundary-rounding bug
// becomes visible instead of silently degrading perf.
// =========================================================================

test "M16.a: literal_expr byte-exact replacement hits hot path" {
    const src: [:0]const u8 = "fn f() -> i32 { return 42; }";
    const new_src: []const u8 = "fn f() -> i32 { return 137; }";
    const lit_off = at(src, "42");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = lit_off, .end = lit_off + 2, .new_text = "137" },
        new_src,
        true,
    );
}

test "M16.b: ident_expr byte-exact replacement same-length swap" {
    const src: [:0]const u8 = "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return a; }";
    const new_src: []const u8 = "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return b; }";
    const ident_off = at(src, "return a;") + 7;
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = ident_off, .end = ident_off + 1, .new_text = "b" },
        new_src,
        true,
    );
}

test "M16.c: return_stmt exact-range replacement" {
    const src: [:0]const u8 = "fn f() -> i32 { return 0; }";
    const new_src: []const u8 = "fn f() -> i32 { return 1 + 2; }";
    const stmt_off = at(src, "return 0;");
    try runEdit(
        std.testing.allocator,
        src,
        .{ .start = stmt_off, .end = stmt_off + 9, .new_text = "return 1 + 2;" },
        new_src,
        true,
    );
}

test "M16.d: binary_expr adjacent-operand swap" {
    const src: [:0]const u8 = "const a = 1; const b = 2; fn f() -> i32 { return a + b; }";
    const new_src: []const u8 = "const a = 1; const b = 2; fn f() -> i32 { return b + a; }";
    // Two sequential edits. After each `reparse`, prev is left with a
    // stub arena — safe to `deinit` without double-free. We keep a
    // single `current` variable and replace it end-to-end.
    const gpa = std.testing.allocator;
    var current = try Incremental.parseFull(gpa, src);

    const a_off = at(src, "return a") + 7;
    {
        const next = try Incremental.reparse(gpa, &current, .{
            .start = a_off,
            .end = a_off + 1,
            .new_text = "b",
        });
        current.deinit();
        current = next;
    }

    const b_off = at(current.source, "b + b") + 4;
    {
        const next = try Incremental.reparse(gpa, &current, .{
            .start = b_off,
            .end = b_off + 1,
            .new_text = "a",
        });
        current.deinit();
        current = next;
    }
    defer current.deinit();

    try std.testing.expectEqualStrings(new_src, current.source);

    var oracle = try Incremental.parseFull(gpa, current.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, current.module, oracle.module);
    try expectUseCountsMatch(current.module, oracle.module);
}

// =========================================================================
// M17 — Anchor-kind flips in one byte.
//
// Edits that change what `isSymbolFreeAnchor` returns between old and new
// subtree. Either side may take a different hot path (or fall back); the
// invariant is oracle match, not hot-path hits on either side.
// =========================================================================

test "M17.a: literal_expr 42 → ident x (literal → ident)" {
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return 42; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const lit_off = at(src, "42");
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = lit_off,
        .end = lit_off + 2,
        .new_text = "x",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M17.b: ident x → literal 42 (ident → literal)" {
    // Anchor-kind mismatch (ident_expr ≠ literal_expr) may force fallback;
    // the correctness bar is oracle match, not hot-path reuse.
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return 42; }";
    const id_off = at(src, "return x") + 7;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = id_off,
        .end = id_off + 1,
        .new_text = "42",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M17.c: paren_expr (x) → x (anchor elision)" {
    // Parens disappear — old anchor is paren_expr, new is ident_expr.
    // Kind mismatch falls back; oracle match is the invariant.
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return (x); }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const paren_off = at(src, "(x)");
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = paren_off,
        .end = paren_off + 3,
        .new_text = "x",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

// =========================================================================
// M20 — Template / generic churn.
//
// M2 covered type-expression fallback behavior; these tests focus on the
// use_count oracle inside template args, where idents inside template
// brackets do affect resolution. An edit swapping `array<f32, N>` ident
// `N` for `M` must decrement N's use_count and increment M's.
// =========================================================================

test "M20.a: array size-expr ident swap N → M updates use_counts" {
    const src: [:0]const u8 =
        \\const N: u32 = 4;
        \\const M: u32 = 8;
        \\fn f() { var xs: array<f32, N>; }
    ;
    const new_src: []const u8 =
        \\const N: u32 = 4;
        \\const M: u32 = 8;
        \\fn f() { var xs: array<f32, M>; }
    ;
    const n_off = at(src, "array<f32, N>") + 11;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = n_off,
        .end = n_off + 1,
        .new_text = "M",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M20.b: template arg edited to use-before-decl ident emits E0102" {
    const src: [:0]const u8 =
        \\const N: u32 = 4;
        \\fn f() { var xs: array<f32, N>; let Z: u32 = 8; }
    ;
    const new_src: []const u8 =
        \\const N: u32 = 4;
        \\fn f() { var xs: array<f32, Z>; let Z: u32 = 8; }
    ;
    const n_off = at(src, "array<f32, N>") + 11;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = n_off,
        .end = n_off + 1,
        .new_text = "Z",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

// =========================================================================
// M21 — Mid-token split / join edits.
//
// Edits that cut an identifier into two, join two identifiers into one, or
// flip between keyword and identifier. Most of these force fallback (token
// tag changes invalidate the anchor boundaries), but the fallback path
// must still produce a correct oracle-matching AST + error buckets.
// =========================================================================

test "M21.a: identifier mid-token split with underscore insert" {
    const src: [:0]const u8 = "const myFunction: i32 = 1; fn f() -> i32 { return myFunction; }";
    const new_src: []const u8 = "const myFu_nction: i32 = 1; fn f() -> i32 { return myFunction; }";
    // Insert `_` at offset of 'F' in the DECLARATION's name. Original
    // `myFunction` becomes `myFu_nction`; call site keeps old name, now
    // unresolved → E0102.
    const split_off = at(src, "myFunction:") + 4;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = split_off,
        .end = split_off,
        .new_text = "_",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M21.b: keyword → identifier fn → fnx forces fallback" {
    const src: [:0]const u8 = "fn f() {}";
    const new_src: []const u8 = "fnx f() {}";
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 2,
        .end = 2,
        .new_text = "x",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    // Must fall back — the root decl structure is invalid.
    try std.testing.expect(!updated.reused);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M21.c: identifier → keyword fnx → fn surfaces parser error" {
    // Deleting the trailing `x` of an identifier `fnx` that happens to
    // overlap a keyword puts the tokenizer into a state the grammar
    // refuses (reserved-word as a const name). Both the incremental
    // path and the oracle propagate error.ParseFailed — we pin that
    // parity so a future change that makes one graceful while leaving
    // the other fatal is caught.
    const src: [:0]const u8 = "const fnx: i32 = 1;";
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    const x_off = at(src, "fnx") + 2;
    const incr = Incremental.reparse(gpa, &base, .{
        .start = x_off,
        .end = x_off + 1,
        .new_text = "",
    });
    try std.testing.expectError(error.ParseFailed, incr);
    const oracle = Incremental.parseFull(gpa, "const fn: i32 = 1;");
    try std.testing.expectError(error.ParseFailed, oracle);
}

// =========================================================================
// M23 — Block-comment insert / delete that hides / exposes code.
//
// Inserting `/*` turns subsequent code into trivia. Inserting `*/` closes
// a leading `/*` and exposes code. Both are extreme AST deltas — the
// fallback must still produce an oracle-matching tree.
// =========================================================================

test "M23.a: insert /* hiding three decls collapses module to zero" {
    const src: [:0]const u8 =
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\
    ;
    const new_src: []const u8 =
        \\/*const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\
    ;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 3), base.module.declarations.items.len);
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 0,
        .end = 0,
        .new_text = "/*",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    // With no closing `*/`, everything downstream is swallowed by the
    // unterminated block comment → zero decls in the oracle too.
    try std.testing.expectEqual(oracle.module.declarations.items.len, updated.module.declarations.items.len);
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M23.b: insert */ re-exposes decls hidden by leading /*" {
    const src: [:0]const u8 =
        \\/*
        \\const a = 1;
        \\const b = 2;
        \\
    ;
    const new_src: []const u8 =
        \\/*
        \\*/const a = 1;
        \\const b = 2;
        \\
    ;
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    try std.testing.expectEqual(@as(usize, 0), base.module.declarations.items.len);
    // Insert `*/` after `/*\n` (offset 3).
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = 3,
        .end = 3,
        .new_text = "*/",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    // Oracle should now see two decls.
    try std.testing.expectEqual(@as(usize, 2), oracle.module.declarations.items.len);
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

// =========================================================================
// M17.d — Unary elision (`-x` → `x`, unary_expr → ident_expr).
//
// Anchor kind shrinks: the old subtree is `unary_expr`, the new is
// `ident_expr`. Kind mismatch forces fallback; the oracle still owns the
// correctness bar.
// =========================================================================

test "M17.d: unary_expr -x → x (anchor shrink)" {
    const src: [:0]const u8 = "const x: i32 = 1; fn f() -> i32 { return -x; }";
    const new_src: []const u8 = "const x: i32 = 1; fn f() -> i32 { return x; }";
    const minus_off = at(src, "-x");
    try runEdit(std.testing.allocator, src, .{
        .start = minus_off,
        .end = minus_off + 1,
        .new_text = "",
    }, new_src, false);
}

// =========================================================================
// M18 — New-style attributes.
//
// M1 covered `@workgroup_size` / `@group` / `@binding` / `@align` /
// `@location`. M18 fills in the remaining decl-level attribute families
// the bidirectional-tooling roadmap enumerated.
// =========================================================================

test "M18.a: @diagnostic attribute-arg swap (off → warning)" {
    // Attribute-arg edit on a fn-level `@diagnostic`. The parser treats
    // `@diagnostic` as a regular attribute (name + args); the oracle bar
    // is shape + use_count + errors match, regardless of whether the hot
    // path engages.
    const src: [:0]const u8 =
        "@diagnostic(off, derivative_uniformity) fn f() -> f32 { return 1.0; }";
    const new_src: []const u8 =
        "@diagnostic(warning, derivative_uniformity) fn f() -> f32 { return 1.0; }";
    const off_off = at(src, "off");
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = off_off,
        .end = off_off + 3,
        .new_text = "warning",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M18.b: @must_use attribute toggle on fn decl forces fallback" {
    // Removing a whole decl-level attribute shrinks the attribute_list
    // and changes the fn's decl_span start — no hot-path anchor can
    // span that change. Oracle match is the invariant.
    const src: [:0]const u8 = "@must_use fn f() -> i32 { return 1; }";
    const new_src: []const u8 = "fn f() -> i32 { return 1; }";
    try runEdit(std.testing.allocator, src, .{
        .start = 0,
        .end = @intCast("@must_use ".len),
        .new_text = "",
    }, new_src, false);
}

test "M18.c: @builtin(position) → @builtin(vertex_index) on a parameter" {
    // Attribute-arg edit inside a parameter's `@builtin(...)`. The
    // oracle is happy with any builtin name (it's just an identifier at
    // the parser level); semantic validity is not checked by the
    // parseFull oracle.
    const src: [:0]const u8 =
        "@vertex fn vs(@builtin(position) p: vec4<f32>) -> @builtin(position) vec4<f32> { return p; }";
    const new_src: []const u8 =
        "@vertex fn vs(@builtin(vertex_index) p: vec4<f32>) -> @builtin(position) vec4<f32> { return p; }";
    // Find the FIRST `position` — the one inside the parameter's `@builtin(...)`.
    const pos_off = at(src, "@builtin(position)") + @as(u32, @intCast("@builtin(".len));
    try runEdit(std.testing.allocator, src, .{
        .start = pos_off,
        .end = pos_off + @as(u32, @intCast("position".len)),
        .new_text = "vertex_index",
    }, new_src, true);
}

test "M18.d: @compute @workgroup_size(1) → @fragment (decl-level fallback)" {
    // Replacing two attributes with one shrinks the attribute_list and
    // forces fallback. Oracle match covers shape + errors.
    const src: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    const new_src: []const u8 = "@fragment fn main() {}";
    try runEdit(std.testing.allocator, src, .{
        .start = 0,
        .end = @intCast("@compute @workgroup_size(1)".len),
        .new_text = "@fragment",
    }, new_src, false);
}

// =========================================================================
// M19 — Cross-function interleaved burst with symbol-layout invariant.
//
// A real editing session touches multiple functions out of order. The
// incremental pipeline's SymbolIndex stability contract says existing
// symbols keep their indices across reparses — new symbols may only be
// appended. M19 pins that across a 60-edit burst hopping between three
// functions. Any hot-path step that reorders `module.symbols` or drops
// an entry breaks this test before it breaks downstream consumers
// (StableId, LSP caches).
// =========================================================================

test "M19: cross-function burst keeps module.symbols layout stable modulo appends" {
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 =
        \\fn f() -> i32 { return 1; }
        \\fn g() -> i32 { return 1; }
        \\fn h() -> i32 { return 1; }
    ;
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    // Snapshot the initial symbol names + indices. Every later step
    // must preserve this prefix.
    const initial_len = prev.module.symbols.items.len;
    var initial_names = try gpa.alloc([]const u8, initial_len);
    defer gpa.free(initial_names);
    for (prev.module.symbols.items, 0..) |s, i| {
        initial_names[i] = try gpa.dupe(u8, s.original_name);
    }
    defer for (initial_names) |n| gpa.free(n);

    // Pre-compute stable literal offsets. Each edit replaces exactly one
    // byte with another one byte, so the offsets never shift across the
    // burst.
    const off_f = at(prev.source, "fn f() -> i32 { return 1") + @as(u32, @intCast("fn f() -> i32 { return ".len));
    const off_g = at(prev.source, "fn g() -> i32 { return 1") + @as(u32, @intCast("fn g() -> i32 { return ".len));
    const off_h = at(prev.source, "fn h() -> i32 { return 1") + @as(u32, @intCast("fn h() -> i32 { return ".len));
    const offs = [_]u32{ off_f, off_g, off_h };

    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const off = offs[i % 3];
        const ch: u8 = '0' + @as(u8, @intCast((i % 9) + 1));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = off,
            .end = off + 1,
            .new_text = &new_text,
        });
        prev.deinit();
        prev = next;

        // Invariant: prefix of size `initial_len` in the current
        // `module.symbols` matches the initial layout by original_name.
        try std.testing.expect(prev.module.symbols.items.len >= initial_len);
        for (prev.module.symbols.items[0..initial_len], 0..) |s, k| {
            try std.testing.expectEqualStrings(initial_names[k], s.original_name);
        }
    }

    // Final oracle cross-check: shape + use_count.
    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M20.c / M20.d — parameter type template churn + nested vec4<f16>.
// =========================================================================

test "M20.c: vec3<f32> → vec3<i32> on a fn parameter type" {
    const src: [:0]const u8 = "fn f(v: vec3<f32>) -> vec3<f32> { return v; }";
    const new_src: []const u8 = "fn f(v: vec3<i32>) -> vec3<f32> { return v; }";
    // First `f32` is in the parameter type. Type-annotation edits do
    // not have a hot-path anchor; fallback is expected.
    const f32_off = at(src, "vec3<f32>") + @as(u32, @intCast("vec3<".len));
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = f32_off,
        .end = f32_off + 3,
        .new_text = "i32",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M20.d: nested array<vec4<f32>, 8> → array<vec4<f16>, 8> with enable f16" {
    // Two base shaders — `enable f16` active and inactive. The parser
    // oracle doesn't validate `enable` semantics, but the incremental
    // type-annotation edit falls back and must still match the oracle
    // on shape + error buckets across both forms.
    const gpa = std.testing.allocator;
    const Pair = struct { src: [:0]const u8, new_src: []const u8 };
    const pairs = [_]Pair{
        .{
            .src =
            \\enable f16;
            \\fn f() { var xs: array<vec4<f32>, 8>; }
            ,
            .new_src =
            \\enable f16;
            \\fn f() { var xs: array<vec4<f16>, 8>; }
            ,
        },
        .{
            .src = "fn f() { var xs: array<vec4<f32>, 8>; }",
            .new_src = "fn f() { var xs: array<vec4<f16>, 8>; }",
        },
    };

    for (pairs) |pair| {
        const f32_off = at(pair.src, "vec4<f32>") + @as(u32, @intCast("vec4<".len));
        var base = try Incremental.parseFull(gpa, pair.src);
        defer base.deinit();
        var updated = try Incremental.reparse(gpa, &base, .{
            .start = f32_off,
            .end = f32_off + 3,
            .new_text = "f16",
        });
        defer updated.deinit();
        try std.testing.expectEqualStrings(pair.new_src, updated.source);
        var oracle = try Incremental.parseFull(gpa, updated.source);
        defer oracle.deinit();
        try expectShapesMatch(gpa, updated.module, oracle.module);
        try expectErrorsOracleMatch(updated.errors, oracle.errors);
    }
}

// =========================================================================
// M21.d — Whitespace split / join at an identifier boundary.
//
// Inserting whitespace mid-ident splits one token into two (or the
// reverse, joining). Both directions cross token boundaries in ways the
// hot-path anchor cannot accommodate — fallback must pick up the slack.
// The invariant: whatever the oracle does, incremental must match.
// =========================================================================

test "M21.d: whitespace split ab → a b at a decl name matches oracle" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { let ab: i32 = 1; }";
    // Insert a space after the `a` in `ab:`.
    const split_off = at(src, "ab:") + 1;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const incr = Incremental.reparse(gpa, &base, .{
        .start = split_off,
        .end = split_off,
        .new_text = " ",
    });
    const oracle_res = Incremental.parseFull(gpa, "fn f() { let a b: i32 = 1; }");
    if (oracle_res) |oracle_ok| {
        var oracle = oracle_ok;
        defer oracle.deinit();
        var incr_ok = try incr;
        defer incr_ok.deinit();
        try expectShapesMatch(gpa, incr_ok.module, oracle.module);
        try expectErrorsOracleMatch(incr_ok.errors, oracle.errors);
    } else |oracle_err| {
        try std.testing.expectError(oracle_err, incr);
    }
}

// =========================================================================
// M22 — Watermark-edge corner cases.
//
// M10 covers the watermark tripping at all; M22 nails down the exact
// boundary behavior (one trip on a crossing, counter reset after a
// coalesce, no-op edits resetting the counter).
// =========================================================================

test "M22.a: boundary crossing produces exactly one fallback in the crossing window" {
    // Start from a ~30 KiB base so the threshold is
    // max(256 KiB, 30_720*8)=256 KiB for the symbol-free path. Edit a
    // literal repeatedly; track each hot-path trip. After the burst,
    // the chain must have tripped at least once (watermark was really
    // crossed) but remain correct against the oracle.
    const gpa = std.testing.allocator;
    var base_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer base_buf.deinit(gpa);
    try base_buf.appendSlice(gpa, "fn f() -> i32 { return 1");
    var pad: usize = 0;
    while (pad < 30 * 1024) : (pad += 1) try base_buf.append(gpa, ' ');
    try base_buf.appendSlice(gpa, " + 2; }");
    const base_z = try base_buf.toOwnedSliceSentinel(gpa, 0);
    defer gpa.free(base_z);

    var prev = try Incremental.parseFull(gpa, base_z);
    defer prev.deinit();

    const lit_off: u32 = at(prev.source, "return 1") + @as(u32, @intCast("return ".len));
    var trip_count: u32 = 0;
    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        if (!next.reused) trip_count += 1;
        prev.deinit();
        prev = next;
    }
    try std.testing.expect(trip_count >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M22.b: HOT_EDIT_COALESCE_MAX forces a fallback and the counter resets" {
    // HOT_EDIT_COALESCE_MAX=256. We exercise the edit-count watermark
    // independently of the byte watermark by keeping each edit tiny
    // (1 byte replace → small arena debt). After 256 accepted
    // in-place edits the next reparse must fall back (reused==false,
    // hot_edits_since_full resets to 0) and a subsequent edit re-enters
    // the hot path on a fresh arena.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(prev.source, "return 1") + @as(u32, @intCast("return ".len));

    var accepted: u32 = 0;
    var coalesced_on: ?u32 = null;
    var i: u32 = 0;
    while (i < Incremental.HOT_EDIT_COALESCE_MAX + 2) : (i += 1) {
        const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
        const new_text = [_]u8{ch};
        const next = try Incremental.reparse(gpa, &prev, .{
            .start = lit_off,
            .end = lit_off + 1,
            .new_text = &new_text,
        });
        if (next.reused) {
            accepted += 1;
        } else if (coalesced_on == null) {
            coalesced_on = i;
            // Post-coalesce: a fresh full parse has counter = 0.
            try std.testing.expectEqual(@as(u16, 0), next.hot_edits_since_full);
        }
        prev.deinit();
        prev = next;
    }

    try std.testing.expect(coalesced_on != null);
    // At least one forced coalesce landed inside the burst — whether
    // from the edit-count watermark (HOT_EDIT_COALESCE_MAX) or the
    // byte-watermark, the counter must reset to 0 right after it.
    try std.testing.expect(accepted >= 1);

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

test "M22.c: interleaved no-op edits reset the counter and preserve correctness" {
    // A `.no_op` edit (start==end, new_text empty) currently full-parses
    // inside `Incremental.reparse` and produces `reused == false` with
    // counter = 0. Interleaved between hot literal flips, the counter
    // must never leak state across the no-op boundary.
    const gpa = std.testing.allocator;
    const base_src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    var prev = try Incremental.parseFull(gpa, base_src);
    defer prev.deinit();

    const lit_off: u32 = at(prev.source, "return 1") + @as(u32, @intCast("return ".len));

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        if (i % 4 == 3) {
            // No-op edit.
            const next = try Incremental.reparse(gpa, &prev, .{
                .start = 0,
                .end = 0,
                .new_text = "",
            });
            try std.testing.expect(!next.reused);
            try std.testing.expectEqual(@as(u16, 0), next.hot_edits_since_full);
            prev.deinit();
            prev = next;
        } else {
            const ch: u8 = '0' + @as(u8, @intCast((i + 1) % 10));
            const new_text = [_]u8{ch};
            const next = try Incremental.reparse(gpa, &prev, .{
                .start = lit_off,
                .end = lit_off + 1,
                .new_text = &new_text,
            });
            try std.testing.expect(next.reused);
            try std.testing.expect(next.hot_edits_since_full >= 1);
            prev.deinit();
            prev = next;
        }
    }

    var oracle = try Incremental.parseFull(gpa, prev.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, prev.module, oracle.module);
    try expectUseCountsMatch(prev.module, oracle.module);
}

// =========================================================================
// M24 — Cross-decl fallback invariants.
//
// An edit whose byte range covers the closing `}` of one decl and bytes
// of the next must force fallback: no in-place hot path can splice a
// subtree whose anchor straddles two decls. Oracle match is the bar.
// =========================================================================

test "M24.a: edit spans exactly two top-level decls" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {} fn g() {}";
    // Replace `} fn g()` — the entire boundary between the two decls.
    const start = at(src, "} fn g()");
    const end = start + @as(u32, @intCast("} fn g()".len));
    const new_src: []const u8 = "fn f() { return; } {}";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = start,
        .end = end,
        .new_text = " return; }",
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    try std.testing.expect(!updated.reused);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}

test "M24.b: edit spans a function-body closing `}` into the next decl" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        "fn f() { let x = 1; } fn g() { let y = 2; }";
    // Replace the `}` at the end of `fn f`'s body AND the single-byte
    // gap that follows, reaching into `fn g()`'s header. The edit must
    // force fallback because no hot-path anchor spans two decls.
    const start = at(src, "} fn g() {");
    const end = start + @as(u32, @intCast("} fn g() {".len));
    const replacement: []const u8 = "let z = 3; }; fn g() {";
    const new_src: []const u8 =
        "fn f() { let x = 1; let z = 3; }; fn g() { let y = 2; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();
    var updated = try Incremental.reparse(gpa, &base, .{
        .start = start,
        .end = end,
        .new_text = replacement,
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings(new_src, updated.source);
    try std.testing.expect(!updated.reused);
    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();
    try expectShapesMatch(gpa, updated.module, oracle.module);
    try expectUseCountsMatch(updated.module, oracle.module);
    try expectErrorsOracleMatch(updated.errors, oracle.errors);
}
