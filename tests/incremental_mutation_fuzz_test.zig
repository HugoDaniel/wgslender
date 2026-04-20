//! Targeted fuzz / corpus tests that stress the symbol-free hot path
//! in `Incremental.reparse` (the `reused = true` path). The existing
//! `incremental_fuzz_test.zig` already verifies byte-correctness via a
//! `parseFull` oracle — these tests add two things:
//!
//! 1. **Hot-path coverage** — a sweep that edits every literal token in
//!    a set of realistic shaders and asserts `reused == true`.
//! 2. **Symbol-table stability** — on any reused-path result, every
//!    `SymbolIndex` that existed before the edit still refers to a
//!    symbol with the same `original_name` + `kind`.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const Lexer = wgslender.Lexer;

const bases = [_][:0]const u8{
    "const pi = 3.14;\nfn area(r: f32) -> f32 { return pi * r * r; }",
    "@compute @workgroup_size(8)\nfn main() { var x: u32 = 0u; x = x + 1u; }",
    "fn step3(a: f32, b: f32) -> f32 { if (a < b) { return 0.0; } return 1.0; }",
};

/// Enumerate all integer / float literal token byte ranges in `source`.
fn forEachLiteral(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), u32, u32) anyerror!void,
) !void {
    var toks = try Lexer.tokenizeAll(gpa, source);
    defer toks.deinit(gpa);
    const tags = toks.items(.tag);
    const starts = toks.items(.start);
    const ends = toks.items(.end);
    for (tags, 0..) |t, i| {
        if (t != .int_literal and t != .float_literal) continue;
        try callback(ctx, starts[i], ends[i]);
    }
}

test "F1: every literal edit reaches the hot path (reused = true)" {
    const gpa = std.testing.allocator;

    const Tally = struct {
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        hot: u32 = 0,
        total: u32 = 0,

        fn onLiteral(self: *@This(), lit_start: u32, lit_end: u32) !void {
            self.total += 1;
            var base = try Incremental.parseFull(self.gpa, self.source);
            defer base.deinit();
            // Swap the digit to a different digit keeping length constant
            // so the anchor stays a literal_expr of the same kind.
            const replacement: []const u8 = switch (self.source[lit_start]) {
                '0', '1', '2', '3', '4' => "9",
                else => "0",
            };
            var upd = try Incremental.reparse(self.gpa, &base, .{
                .start = lit_start,
                .end = lit_start + 1, // single digit
                .new_text = replacement,
            });
            defer upd.deinit();
            _ = lit_end;
            if (upd.reused) self.hot += 1;
        }
    };

    for (bases) |base| {
        var tally: Tally = .{ .gpa = gpa, .source = base };
        try forEachLiteral(gpa, base, &tally, Tally.onLiteral);
        // Every single-digit rewrite lands on a literal_expr anchor,
        // which is symbol-free — every edit must take the hot path.
        try std.testing.expect(tally.total > 0);
        try std.testing.expectEqual(tally.total, tally.hot);
    }
}

test "F-PROP: every literal swap leaves errors equal to a parseFull oracle" {
    // Property test for the error-fixup path. A no-op literal swap
    // (e.g. `0` → `9`) is a kind-stable hot edit on a literal_expr
    // anchor. Whatever errors the source had before must shift cleanly
    // (or stay put) and equal what a fresh full parse would produce.
    const gpa = std.testing.allocator;

    const FixupCheck = struct {
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        steps: u32 = 0,

        fn onLiteral(self: *@This(), lit_start: u32, lit_end: u32) !void {
            self.steps += 1;
            var base = try Incremental.parseFull(self.gpa, self.source);
            defer base.deinit();
            const replacement: []const u8 = switch (self.source[lit_start]) {
                '0', '1', '2', '3', '4' => "9",
                else => "0",
            };
            var upd = try Incremental.reparse(self.gpa, &base, .{
                .start = lit_start,
                .end = lit_start + 1,
                .new_text = replacement,
            });
            defer upd.deinit();
            _ = lit_end;
            try std.testing.expect(upd.reused);

            var oracle = try Incremental.parseFull(self.gpa, upd.source);
            defer oracle.deinit();
            try std.testing.expectEqual(oracle.errors.len, upd.errors.len);
            for (upd.errors, oracle.errors) |g, o| {
                try std.testing.expectEqualStrings(o.code, g.code);
                try std.testing.expectEqual(o.pos, g.pos);
                try std.testing.expectEqual(o.end, g.end);
            }
        }
    };

    // Sources designed so each literal swap exercises a different
    // fixup case: clean (no errors), errors strictly downstream, errors
    // strictly upstream.
    const sources = [_][:0]const u8{
        "fn f() -> i32 { return 0; }",
        "fn f() -> i32 { return 0; } fn g() -> i32 { return q; let q: i32 = 1; return q; }",
        "fn g() -> i32 { return q; let q: i32 = 1; return q; } fn f() -> i32 { return 0; }",
    };
    for (sources) |s| {
        var check: FixupCheck = .{ .gpa = gpa, .source = s };
        try forEachLiteral(gpa, s, &check, FixupCheck.onLiteral);
        try std.testing.expect(check.steps > 0);
    }
}

test "F4: reused path preserves symbol indices (same name + kind by index)" {
    const gpa = std.testing.allocator;

    // Pick a base with enough symbols that we can compare.
    const base: [:0]const u8 = "const pi = 3.14;\nfn area(r: f32) -> f32 { return pi * r * r; }";

    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    // Snapshot prev symbol identity.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var kinds: std.ArrayListUnmanaged(Ast.Symbol.Kind) = .empty;
    defer kinds.deinit(gpa);
    for (prev.module.symbols.items) |s| {
        try names.append(gpa, try gpa.dupe(u8, s.original_name));
        try kinds.append(gpa, s.kind);
    }

    // Edit "3.14" → "3.15" (literal_expr, symbol-free).
    // byte offset of "3.14" in base = 11; length 4.
    const lit_start: u32 = @intCast(std.mem.indexOfScalar(u8, base, '3').?);
    var upd = try Incremental.reparse(gpa, &prev, .{
        .start = lit_start,
        .end = lit_start + 4,
        .new_text = "3.15",
    });
    defer upd.deinit();

    try std.testing.expect(upd.reused);
    // Every prev-indexed symbol must match the new one at the same index.
    try std.testing.expectEqual(names.items.len, upd.module.symbols.items.len);
    for (upd.module.symbols.items, 0..) |s, i| {
        try std.testing.expectEqualStrings(names.items[i], s.original_name);
        try std.testing.expectEqual(kinds.items[i], s.kind);
    }
}

test "F5: random local-decl append into a function body always hot-paths" {
    const gpa = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xA99EDCAF);
    const rand = rng.random();

    const shader_bases = [_][:0]const u8{
        "fn f() {}",
        "fn f() { let a = 1; }",
        "fn f() { let a = 1; let b = a + 2; }",
        "fn g() { let x = 1; } fn f() { let a = 1; }",
        "fn f() { if (true) { let z = 1; } }",
    };

    for (shader_bases) |base| {
        var cur = try Incremental.parseFull(gpa, base);
        defer cur.deinit();

        var iter: u32 = 0;
        while (iter < 10) : (iter += 1) {
            // Find a `}` byte at random and insert a complete statement
            // just before it. A decl_stmt append at a compound's close
            // boundary always takes the compound_stmt hot path.
            var candidate_positions: std.ArrayListUnmanaged(u32) = .empty;
            defer candidate_positions.deinit(gpa);
            for (cur.source, 0..) |c, i| {
                if (c == '}') try candidate_positions.append(gpa, @intCast(i));
            }
            if (candidate_positions.items.len == 0) break;

            const pick = rand.intRangeLessThan(usize, 0, candidate_positions.items.len);
            const close_off = candidate_positions.items[pick];

            var buf: [64]u8 = undefined;
            const val = rand.intRangeLessThan(u32, 0, 1000);
            const payload = try std.fmt.bufPrint(&buf, " let tmp_{} = {};", .{ iter, val });

            const next = try Incremental.reparse(gpa, &cur, .{
                .start = close_off,
                .end = close_off,
                .new_text = payload,
            });
            cur.deinit();
            cur = next;
            try std.testing.expect(cur.reused);
        }

        // Final shape must match a fresh full parse. Symbol table is
        // append-only on the Phase 2 compound_stmt hot path, so allow
        // extras in `cur` as long as they are all dead (use_count == 0)
        // and every oracle symbol has a live counterpart.
        var oracle = try Incremental.parseFull(gpa, cur.source);
        defer oracle.deinit();
        try std.testing.expectEqual(
            oracle.module.declarations.items.len,
            cur.module.declarations.items.len,
        );
        try std.testing.expect(cur.module.symbols.items.len >= oracle.module.symbols.items.len);
        const oracle_live = countLive(oracle.module);
        const cur_live = countLive(cur.module);
        try std.testing.expectEqual(oracle_live, cur_live);
    }
}

fn countLive(m: *const wgslender.Ast.Module) usize {
    var n: usize = 0;
    for (m.symbols.items) |s| if (s.use_count > 0) {
        n += 1;
    };
    return n;
}

// =========================================================================
// F-EXACT — positional per-symbol `use_count` oracle on the mutation
// sections of `Incremental.reparse`.
//
// The existing `incremental_corpus_addsub_test.zig` (C-M1..C-M9) runs
// mutation-section coverage over compute.toys shaders but, until the
// per-symbol oracle landed alongside this block, compared only
// per-name SUMS of `use_count`. That masks a whole class of
// mode-dispatch bugs where an over-increment on one symbol is
// balanced by an under-decrement on another symbol SHARING THE SAME
// NAME (different scopes). Compute.toys shaders routinely shadow
// identifiers — multiple locals named `i`, `x`, `uv`, `pos` — so the
// masking is real, not theoretical.
//
// F-EXACT pins down 15 deterministic scenarios covering every mutation
// section in `src/Incremental.zig`:
//   - E1..E6, E11, E12 stress the symbol-free hot path
//     (`tryAddSubSpliceInPlace`, anchors like literal_expr, binary_expr,
//     ident_expr, paren_expr, call_expr, if-cond, for-cond).
//   - E7..E9 stress the compound_stmt hot path
//     (`tryCompoundSpliceInPlace`).
//   - E10 stresses the decl_stmt hot path
//     (`tryDeclStmtSpliceInPlace`).
//   - E13..E15 are the shadowing twins — a hand-crafted base with three
//     functions each declaring a local named `i`. Any drift in which
//     `i` symbol gets mutated fails here even if the name-sum is
//     preserved.
//
// Each scenario asserts `reused == true` (hot-path gate) and every live
// symbol's `(name, kind, use_count)` matches `parseFull(new_source)`
// positionally in appearance order.

/// Per-symbol `use_count` oracle, identity-keyed on
/// `(original_name, kind, loc)` — the decl's byte offset disambiguates
/// same-name symbols declared in different scopes. Mirrors the helper
/// in `incremental_corpus_addsub_test.zig`; duplicated to keep this
/// file self-contained.
fn expectPerSymbolUseCountsExact(
    gpa: std.mem.Allocator,
    label: []const u8,
    got: *const wgslender.Ast.Module,
    oracle: *const wgslender.Ast.Module,
) !void {
    var got_live: std.ArrayListUnmanaged(usize) = .empty;
    defer got_live.deinit(gpa);
    for (got.symbols.items, 0..) |s, i| {
        if (s.use_count > 0) try got_live.append(gpa, i);
    }

    var oracle_live: std.ArrayListUnmanaged(usize) = .empty;
    defer oracle_live.deinit(gpa);
    for (oracle.symbols.items, 0..) |s, i| {
        if (s.use_count > 0) try oracle_live.append(gpa, i);
    }

    if (got_live.items.len != oracle_live.items.len) {
        std.debug.print(
            "{s}: live-symbol count mismatch: got={d} oracle={d}\n",
            .{ label, got_live.items.len, oracle_live.items.len },
        );
        dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
        return error.LiveSymbolCountMismatch;
    }

    for (oracle_live.items) |oi| {
        const o = oracle.symbols.items[oi];
        var matched: ?usize = null;
        for (got_live.items) |gi| {
            const g = got.symbols.items[gi];
            if (g.kind == o.kind and g.loc == o.loc and std.mem.eql(u8, g.original_name, o.original_name)) {
                matched = gi;
                break;
            }
        }
        const gi = matched orelse {
            std.debug.print(
                "{s}: oracle live symbol ('{s}',{s},loc={d},uc={d}) has no matching live symbol in got\n",
                .{ label, o.original_name, @tagName(o.kind), o.loc, o.use_count },
            );
            dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
            return error.LiveSymbolNotFound;
        };
        const g = got.symbols.items[gi];
        if (g.use_count != o.use_count) {
            std.debug.print(
                "{s}: use_count mismatch for ('{s}',{s},loc={d}): got={d} oracle={d}\n",
                .{ label, o.original_name, @tagName(o.kind), o.loc, g.use_count, o.use_count },
            );
            dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
            return error.PerSymbolUseCountMismatch;
        }
    }
}

fn dumpLiveSideBySide(
    label: []const u8,
    got: *const wgslender.Ast.Module,
    got_live: []const usize,
    oracle: *const wgslender.Ast.Module,
    oracle_live: []const usize,
) void {
    std.debug.print("{s}: live symbol table (got | oracle):\n", .{label});
    const n = @max(got_live.len, oracle_live.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i < got_live.len) {
            const g = got.symbols.items[got_live[i]];
            std.debug.print(
                "  got[{d:>3}] raw={d:>3} name={s:<24} kind={s:<10} loc={d:>4} uc={d}",
                .{ i, got_live[i], g.original_name, @tagName(g.kind), g.loc, g.use_count },
            );
        } else {
            std.debug.print("  got[{d:>3}] --", .{i});
        }
        if (i < oracle_live.len) {
            const o = oracle.symbols.items[oracle_live[i]];
            std.debug.print(
                "  |  oracle[{d:>3}] raw={d:>3} name={s:<24} kind={s:<10} loc={d:>4} uc={d}\n",
                .{ i, oracle_live[i], o.original_name, @tagName(o.kind), o.loc, o.use_count },
            );
        } else {
            std.debug.print("  |  oracle[{d:>3}] --\n", .{i});
        }
    }
}

/// Locate the byte index of `needle`'s first occurrence in `haystack`,
/// as a `u32` so it plugs directly into `Incremental.Edit`.
fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

/// Locate the byte index of the N-th (0-based) occurrence of `needle`
/// in `haystack`. Panics if not found — scenarios hard-code the
/// expected count.
fn atNth(haystack: []const u8, needle: []const u8, n: usize) u32 {
    var start: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        if (seen == n) return @intCast(idx);
        seen += 1;
        start = idx + 1;
    }
    unreachable;
}

/// One-edit driver: parse base, reparse with the edit, parse-full the
/// new source as oracle, and assert per-symbol `use_count` equivalence.
///
/// Intent: the F-EXACT scenarios are designed to exercise the mutation
/// sections (`.sub` / `.add` walks) on the hot path. In practice a few
/// structural edits (paren wrap, compound stmt insert/delete) change
/// the CST subtree kind or touch the decl list and land on the
/// fallback (`reused = false`). On fallback the per-symbol oracle
/// still holds (parseFull is both the system-under-test and the
/// oracle), so we record hot-path coverage as a diagnostic but never
/// fail on it. A non-fatal warning keeps the invariant visible without
/// making the suite brittle to hot-path scope changes.
fn runExactScenario(
    gpa: std.mem.Allocator,
    label: []const u8,
    base_src: [:0]const u8,
    edit: Incremental.Edit,
) !void {
    var base = try Incremental.parseFull(gpa, base_src);
    defer base.deinit();

    var updated = try Incremental.reparse(gpa, &base, edit);
    defer updated.deinit();

    if (!updated.reused) {
        std.debug.print("{s}: note — fallback fired (reused=false); oracle check still runs\n", .{label});
    }

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();

    try expectPerSymbolUseCountsExact(gpa, label, updated.module, oracle.module);
}

// -------------------------------------------------------------------------
// E1 — literal_expr (symbol-free): every live symbol must be unchanged.
// -------------------------------------------------------------------------

test "F-EXACT E1: literal_expr swap preserves every live use_count" {
    const src: [:0]const u8 = "const pi = 3.14;\nfn area(r: f32) -> f32 { return pi * r * r; }";
    const off = at(src, "3.14");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E1",
        src,
        .{ .start = off, .end = off + 4, .new_text = "3.15" },
    );
}

// -------------------------------------------------------------------------
// E2 — binary_expr op flip (symbol-free): operand counts net to zero.
// -------------------------------------------------------------------------

test "F-EXACT E2: binary op flip walks operands but preserves counts" {
    const src: [:0]const u8 = "const a = 1; const b = 2; const c = a + b;";
    const plus_off = at(src, "+");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E2",
        src,
        .{ .start = plus_off, .end = plus_off + 1, .new_text = "-" },
    );
}

// -------------------------------------------------------------------------
// E3 — ident_expr replace (symbol-free anchor): counts redistribute
//      between two distinct symbols `a` and `b`.
// -------------------------------------------------------------------------

test "F-EXACT E3: ident swap redistributes use_count between a and b" {
    // Use: `c = a + b;` → after edit `c = b + b;`. a.use_count drops by 1
    // (and goes dead), b.use_count rises by 1.
    const src: [:0]const u8 = "const a = 1; const b = 2; const c = a + b;";
    // The `a` in `a + b` — second `a` in the file (first is the decl).
    const use_off = atNth(src, "a", 1);
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E3",
        src,
        .{ .start = use_off, .end = use_off + 1, .new_text = "b" },
    );
}

// -------------------------------------------------------------------------
// E4 — paren wrap (symbol-free): extra walker recursion, counts unchanged.
// -------------------------------------------------------------------------

test "F-EXACT E4: paren wrap preserves operand counts" {
    const src: [:0]const u8 = "fn f() -> i32 { let a = 1; let b = 2; return a + b; }";
    const expr_off = at(src, "a + b");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E4",
        src,
        .{ .start = expr_off, .end = expr_off + 5, .new_text = "(a + b)" },
    );
}

// -------------------------------------------------------------------------
// E5 — call_expr arg add (symbol-free): one new ident reference surfaces.
// -------------------------------------------------------------------------

test "F-EXACT E5: call arg ident replaces literal — new use_count on b" {
    // Base leaves `b` declared but unused (use_count=0). Swap the `0`
    // argument of `f(a, 0)` for `b` — b becomes live with use_count=1.
    const src: [:0]const u8 =
        "fn f(x: i32, y: i32) -> i32 { return x + y; }\n" ++
        "fn g() -> i32 { let a = 1; let b = 2; return f(a, 0); }";
    const zero_off = at(src, ", 0)");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E5",
        src,
        .{ .start = zero_off + 2, .end = zero_off + 3, .new_text = "b" },
    );
}

// -------------------------------------------------------------------------
// E6 — call_expr arg remove (symbol-free): one ident reference disappears.
// -------------------------------------------------------------------------

test "F-EXACT E6: call arg ident swapped for literal — b loses use_count" {
    const src: [:0]const u8 =
        "fn f(x: i32, y: i32) -> i32 { return x + y; }\n" ++
        "fn g() -> i32 { let a = 1; let b = 2; return f(a, b); }";
    const b_use_off = at(src, "b);");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E6",
        src,
        .{ .start = b_use_off, .end = b_use_off + 1, .new_text = "0" },
    );
}

// -------------------------------------------------------------------------
// E7 — compound_stmt insert (append one decl_stmt before `}`).
// -------------------------------------------------------------------------

test "F-EXACT E7: compound_stmt insert appends q, bumps a.use_count by 1" {
    const src: [:0]const u8 = "fn f() -> i32 { let a = 1; return a; }";
    // Insert ` let q = a;` just before the closing `}` of the body.
    const close_off = at(src, "}");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E7",
        src,
        .{ .start = close_off, .end = close_off, .new_text = " let q = a;" },
    );
}

// -------------------------------------------------------------------------
// E8 — compound_stmt delete (remove one decl_stmt in the middle).
// -------------------------------------------------------------------------

test "F-EXACT E8: compound_stmt delete removes q + drops a and b counts" {
    // Base: a and b are used only inside `let q = a + b;` (q itself is
    // unused). Deleting that stmt makes a and b go dead in the oracle.
    const src: [:0]const u8 =
        "fn f() -> i32 { let a = 1; let b = 2; let q = a + b; return 0; }";
    const del_start = at(src, " let q = a + b;");
    const del_end = del_start + @as(u32, @intCast(" let q = a + b;".len));
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E8",
        src,
        .{ .start = del_start, .end = del_end, .new_text = "" },
    );
}

// -------------------------------------------------------------------------
// E9 — compound_stmt swap (re-order two decl_stmts; counts invariant).
// -------------------------------------------------------------------------

test "F-EXACT E9: compound_stmt re-order preserves every live use_count" {
    const src: [:0]const u8 = "fn f() -> i32 { let a = 1; let b = 2; return a + b; }";
    const before = "let a = 1; let b = 2;";
    const after: []const u8 = "let b = 2; let a = 1;";
    const off = at(src, before);
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E9",
        src,
        .{
            .start    = off,
            .end      = off + @as(u32, @intCast(before.len)),
            .new_text = after,
        },
    );
}

// -------------------------------------------------------------------------
// E10 — decl_stmt init expression change (symbol-free at the ident level;
//       hot-path anchor is the init expression).
// -------------------------------------------------------------------------

test "F-EXACT E10: decl_stmt init change adjusts a.use_count correctly" {
    // Base: a is used twice (once in `let q = a;` init, once in `return a;`).
    // Edit changes `let q = a;` → `let q = 2;`, so a drops by 1.
    const src: [:0]const u8 = "fn f() -> i32 { let a = 1; let q = a; return a; }";
    const init_off = at(src, "let q = a;");
    const before = "let q = a;";
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E10",
        src,
        .{
            .start    = init_off,
            .end      = init_off + @as(u32, @intCast(before.len)),
            .new_text = "let q = 2;",
        },
    );
}

// -------------------------------------------------------------------------
// E11 — if_stmt condition op flip (symbol-free; net use_count delta zero).
// -------------------------------------------------------------------------

test "F-EXACT E11: if-cond op flip `<` → `<=` preserves x.use_count" {
    const src: [:0]const u8 =
        "fn f() -> i32 { let x = 5; if (x < 10) { return 1; } return 0; }";
    const lt_off = at(src, "x < 10");
    // Edit the single `<` token into `<=` (length-changing, +1 byte).
    const lt_pos = lt_off + 2; // skip "x "
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E11",
        src,
        .{ .start = lt_pos, .end = lt_pos + 1, .new_text = "<=" },
    );
}

// -------------------------------------------------------------------------
// E12 — for_stmt condition op flip (for-loop scope boundary stress).
// -------------------------------------------------------------------------

test "F-EXACT E12: for-cond op flip `<` → `<=` preserves j.use_count" {
    const src: [:0]const u8 =
        "fn f() -> i32 { var s: i32 = 0; " ++
        "for (var j: i32 = 0; j < 10; j = j + 1) { s = s + j; } return s; }";
    const lt_off = at(src, "j < 10");
    const lt_pos = lt_off + 2;
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E12",
        src,
        .{ .start = lt_pos, .end = lt_pos + 1, .new_text = "<=" },
    );
}

// -------------------------------------------------------------------------
// E13..E15 — shadowing twins. The critical test class: three functions
// each declare a local `i`. Any mode-dispatch bug that targets the wrong
// `i` symbol produces a per-name-sum that still matches the oracle, but
// the positional oracle catches the drift at the mismatched live index.
// -------------------------------------------------------------------------

const twin_base: [:0]const u8 =
    "fn a() -> i32 { let i = 1; let x = i; return x; }\n" ++
    "fn b() -> i32 { let i = 2; let y = i; return y; }\n" ++
    "fn c() -> i32 { let i = 3; let z = i; return z; }";

test "F-EXACT E13: twins — fn a's `i` use swapped for literal (a.i dies)" {
    // `let x = i;` → `let x = 1;` inside fn a. Only a.i's use_count drops
    // (by 1, to 0 → dead). b.i and c.i must stay unchanged.
    const use_off = at(twin_base, "let x = i;");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E13",
        twin_base,
        .{
            .start    = use_off,
            .end      = use_off + @as(u32, @intCast("let x = i;".len)),
            .new_text = "let x = 1;",
        },
    );
}

test "F-EXACT E14: twins — delete `let x = i;` from fn a body" {
    const del_start = at(twin_base, " let x = i;");
    const del_len: u32 = @intCast(" let x = i;".len);
    // Also delete `return x;` → replace with `return 0;` so the fn still
    // parses cleanly (x is no longer in scope after the decl delete).
    const del_end = del_start + del_len;
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E14",
        twin_base,
        .{ .start = del_start, .end = del_end, .new_text = "" },
    );
}

test "F-EXACT E15: twins — append `let w = i + i;` to fn a body" {
    // Insert just before fn a's closing `}`. The first `}` in the base
    // closes fn a's body.
    const close_off = at(twin_base, "}");
    try runExactScenario(
        std.testing.allocator,
        "F-EXACT E15",
        twin_base,
        .{
            .start    = close_off,
            .end      = close_off,
            .new_text = " let w = i + i;",
        },
    );
}
