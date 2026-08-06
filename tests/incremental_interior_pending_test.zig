//! Targeted tests for the per-decl `interior_pending` bias mechanism —
//! the replacement for the old O(module) `shiftAstSpans`. Each scenario
//! exercises a specific state transition of the bias (bump, absorb,
//! drain across readers) that the existing mutation / fuzz corpora do
//! not assert directly.
//!
//! Groups (following §4 / §5 of the plan):
//!   - IP-bias-*   : bias state after simple edits
//!   - IP-burst-*  : burst scenarios that defer/absorb across multiple edits
//!   - IP-read-*   : external readers see current coords after incremental edits
//!   - IP-edge-*   : zero-delta, fallback-then-hot-path, round-trip

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const Validator = wgslender.Validator;
const StableId = wgslender.StableId;
const Edits = wgslender.Edits;

// =========================================================================
// Helpers
// =========================================================================

fn expectBias(module: *const Ast.Module, decl_idx: usize, expected: i64) !void {
    const got = Ast.declInteriorPending(module.declarations.items[decl_idx]);
    try std.testing.expectEqual(expected, got);
}

fn findDeclBySymbolName(module: *const Ast.Module, name: []const u8) ?usize {
    for (module.declarations.items, 0..) |d, i| {
        const ref = d.nameRef();
        if (!ref.isValid()) continue;
        if (std.mem.eql(u8, module.symbols.items[ref.index()].original_name, name)) return i;
    }
    return null;
}

/// Drive a single edit and return the resulting ReparseResult. Caller
/// owns the result via its own `deinit`.
fn stepEdit(
    gpa: std.mem.Allocator,
    prev: *Incremental.ReparseResult,
    edit: Incremental.Edit,
) !Incremental.ReparseResult {
    return try Incremental.reparse(gpa, prev, edit);
}

// =========================================================================
// IP-bias-* — direct bias-state assertions
// =========================================================================

test "IP-bias-01: edit inside first function leaves its own bias at 0" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Insert inside f's body.
    const close = std.mem.indexOfScalarPos(u8, base.source, 0, '}').?;
    var next = try stepEdit(gpa, &base, .{
        .start = @intCast(close),
        .end = @intCast(close),
        .new_text = " let x = 1;",
    });
    defer next.deinit();
    try std.testing.expect(next.reused);

    // f is the owner — its interior was walked eagerly; bias = 0.
    const f_idx = findDeclBySymbolName(next.module, "f").?;
    try expectBias(next.module, f_idx, 0);
}

test "IP-bias-02: edit inside first function defers second function's bias" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const close_f = std.mem.indexOfScalarPos(u8, base.source, 0, '}').?;
    var next = try stepEdit(gpa, &base, .{
        .start = @intCast(close_f),
        .end = @intCast(close_f),
        .new_text = " let x = 1;", // 11 bytes
    });
    defer next.deinit();
    try std.testing.expect(next.reused);

    // g is strictly after the edit → non-owner → bias = +11.
    const g_idx = findDeclBySymbolName(next.module, "g").?;
    try expectBias(next.module, g_idx, 11);
}

test "IP-bias-03: two sequential edits inside the same function keep owner bias 0" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    // Two inserts, each inside f's body.
    var i: u32 = 0;
    var hot_path_hits: usize = 0;
    while (i < 2) : (i += 1) {
        const close = std.mem.indexOfScalarPos(u8, cur.source, 0, '}').?;
        const next = try stepEdit(gpa, &cur, .{
            .start = @intCast(close),
            .end = @intCast(close),
            .new_text = " let x = 1;",
        });
        cur.deinit();
        cur = next;
        if (cur.reused) hot_path_hits += 1;
    }

    const f_idx = findDeclBySymbolName(cur.module, "f").?;
    const g_idx = findDeclBySymbolName(cur.module, "g").?;
    try expectBias(cur.module, f_idx, 0);
    if (hot_path_hits == 2) {
        // Both edits hot-pathed → g's bias accumulates delta1 + delta2.
        try expectBias(cur.module, g_idx, 22); // 11 + 11
    } else {
        // One or both edits fell back to parseFull → fresh decls carry
        // bias 0. Just assert we still have the expected shape.
        try std.testing.expectEqual(@as(i64, 0), Ast.declInteriorPending(cur.module.declarations.items[g_idx]));
    }
}

test "IP-bias-04: absorb on owning decl when subsequent edit targets it" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    // Edit 1: inside f. Defers g.
    {
        const close_f = std.mem.indexOfScalarPos(u8, cur.source, 0, '}').?;
        const n = try stepEdit(gpa, &cur, .{
            .start = @intCast(close_f),
            .end = @intCast(close_f),
            .new_text = " let x = 1;",
        });
        cur.deinit();
        cur = n;
    }
    // g has bias = +11.

    // Edit 2: inside g. absorbOwnerFor must drain g's bias before the
    // find/descend; shiftModuleForEdit sees g with existing_bias = 0.
    {
        // g's close brace is the LAST '}' in cur.source.
        const close_g = std.mem.lastIndexOfScalar(u8, cur.source, '}').?;
        const n = try stepEdit(gpa, &cur, .{
            .start = @intCast(close_g),
            .end = @intCast(close_g),
            .new_text = " let y = 2;",
        });
        cur.deinit();
        cur = n;
        try std.testing.expect(cur.reused);
    }

    const f_idx = findDeclBySymbolName(cur.module, "f").?;
    const g_idx = findDeclBySymbolName(cur.module, "g").?;
    // After absorb during find + eager walk during shift, g is again owner with bias=0.
    try expectBias(cur.module, g_idx, 0);
    // f's bias never got bumped (edit is after f).
    try expectBias(cur.module, f_idx, 0);
}

test "IP-bias-05: zero-delta edit does not bump any bias" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Replace "fn f" with "fn h" — same length, still valid WGSL.
    const start = std.mem.indexOf(u8, base.source, "fn f").?;
    var next = try stepEdit(gpa, &base, .{
        .start = @intCast(start),
        .end = @intCast(start + 4),
        .new_text = "fn h",
    });
    defer next.deinit();

    // Whether this edit takes the hot path or falls back, the delta is
    // zero, so no bump can have happened on ANY decl.
    for (next.module.declarations.items) |d| {
        try std.testing.expectEqual(@as(i64, 0), Ast.declInteriorPending(d));
    }
}

// =========================================================================
// IP-burst-* — bias lifetimes across multiple edits
// =========================================================================

test "IP-burst-01: alternating bursts across three functions" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}\nfn h() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    const names = [_][]const u8{ "fn f", "fn g", "fn h" };
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const target = names[i % 3];
        const f_start = std.mem.indexOf(u8, cur.source, target).?;
        const brace = std.mem.indexOfScalarPos(u8, cur.source, f_start, '{').?;
        const close = std.mem.indexOfScalarPos(u8, cur.source, brace, '}').?;
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, " let v{} = {};", .{ i, i });
        const next = try stepEdit(gpa, &cur, .{
            .start = @intCast(close),
            .end = @intCast(close),
            .new_text = payload,
        });
        cur.deinit();
        cur = next;
        try std.testing.expect(cur.reused);
    }

    // Final AST must shape-match a full reparse of the current source.
    const source_z = try gpa.dupeZ(u8, cur.source);
    defer gpa.free(source_z);
    var oracle = try Incremental.parseFull(gpa, source_z);
    defer oracle.deinit();
    try std.testing.expectEqual(
        oracle.module.declarations.items.len,
        cur.module.declarations.items.len,
    );
}

test "IP-burst-02: 20 edits inside a single function keeps other decls' biases bumped" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}\nfn h() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    var total_delta: i32 = 0;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const f_start = std.mem.indexOf(u8, cur.source, "fn f").?;
        const brace = std.mem.indexOfScalarPos(u8, cur.source, f_start, '{').?;
        const close = std.mem.indexOfScalarPos(u8, cur.source, brace, '}').?;
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, " let v{} = {};", .{ i, i });
        const next = try stepEdit(gpa, &cur, .{
            .start = @intCast(close),
            .end = @intCast(close),
            .new_text = payload,
        });
        cur.deinit();
        cur = next;
        try std.testing.expect(cur.reused);
        total_delta += @intCast(payload.len);
    }

    // f was owner on every edit → its bias is 0.
    const f_idx = findDeclBySymbolName(cur.module, "f").?;
    const g_idx = findDeclBySymbolName(cur.module, "g").?;
    const h_idx = findDeclBySymbolName(cur.module, "h").?;
    try expectBias(cur.module, f_idx, 0);
    // g and h are strictly after f → bias accumulates to total_delta.
    try expectBias(cur.module, g_idx, total_delta);
    try expectBias(cur.module, h_idx, total_delta);
}

// =========================================================================
// IP-read-* — reader absorption contracts
// =========================================================================

test "IP-read-01: Validator.analyze absorbs all pending bias" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() { let zz = 3; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Edit inside f → defers g's bias.
    const close_f = std.mem.indexOfScalarPos(u8, base.source, 0, '}').?;
    var cur = try stepEdit(gpa, &base, .{
        .start = @intCast(close_f),
        .end = @intCast(close_f),
        .new_text = " let x = 1;",
    });
    defer cur.deinit();
    try std.testing.expect(cur.reused);

    const g_idx = findDeclBySymbolName(cur.module, "g").?;
    try std.testing.expect(Ast.declInteriorPending(cur.module.declarations.items[g_idx]) != 0);

    // Validator.analyze must drain bias so diagnostics use current coords.
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    _ = try Validator.analyze(arena_inst.allocator(), cur.module, .{});

    // Every bias must now be zero — absorb contract.
    for (cur.module.declarations.items) |d| {
        try std.testing.expectEqual(@as(i64, 0), Ast.declInteriorPending(d));
    }
}

test "IP-read-02: StableId.locateType returns current coords after an edit" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nconst C: f32 = 3.14;";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Edit inside f → pushes C's `f32` span forward.
    const close_f = std.mem.indexOfScalarPos(u8, base.source, 0, '}').?;
    var cur = try stepEdit(gpa, &base, .{
        .start = @intCast(close_f),
        .end = @intCast(close_f),
        .new_text = " let tmp = 1;",
    });
    defer cur.deinit();

    // Compute the stable ID of C on the oracle (fresh parse of new source)
    // and use the same ID against `cur`. The resulting range must point
    // to "f32" in the CURRENT source.
    const source_z = try gpa.dupeZ(u8, cur.source);
    defer gpa.free(source_z);
    var oracle = try Incremental.parseFull(gpa, source_z);
    defer oracle.deinit();

    const c_idx_oracle = findDeclBySymbolName(oracle.module, "C").?;
    const c_sym_oracle = oracle.module.declarations.items[c_idx_oracle].nameRef();
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const sid = (try StableId.stableIdFor(arena_inst.allocator(), oracle.module, c_sym_oracle)).?;

    const range = StableId.locateType(cur.module, sid.bytes).?;
    try std.testing.expectEqualStrings("f32", cur.source[range.start..range.end]);
}

test "IP-read-03: Edits.findReferences returns current coords after an edit" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {}
        \\fn consume() { let a = 1; let b = a; let c = a; }
    ;
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Insert inside f to bump `consume()`'s bias.
    const close_f = std.mem.indexOfScalarPos(u8, base.source, 0, '}').?;
    var cur = try stepEdit(gpa, &base, .{
        .start = @intCast(close_f),
        .end = @intCast(close_f),
        .new_text = " let z = 7;",
    });
    defer cur.deinit();

    // Find the symbol `a` in `use` and collect its references.
    const consume_idx = findDeclBySymbolName(cur.module, "consume").?;
    const consume_decl = cur.module.declarations.items[consume_idx];
    const body = consume_decl.function.body.?;

    // Extract `a`'s SymbolIndex from the first decl_stmt.
    const first_stmt = body.stmts.items[0];
    const a_sym = first_stmt.decl.decl.nameRef();
    try std.testing.expect(a_sym.isValid());

    const refs = try Edits.findReferences(gpa, cur.module, a_sym, false);
    defer gpa.free(refs);

    // Each reference must point to "a" in the CURRENT source.
    for (refs) |r| {
        try std.testing.expectEqualStrings("a", cur.source[r.start..r.end]);
    }
    // At least two refs (b = a, c = a) for a non-trivial sanity check.
    try std.testing.expect(refs.len >= 2);
}

// =========================================================================
// IP-edge-* — edge cases
// =========================================================================

test "IP-edge-01: fallback reparse resets biases via fresh module" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    // Edit 1: hot path inside f. Defers g.
    {
        const close_f = std.mem.indexOfScalarPos(u8, cur.source, 0, '}').?;
        const n = try stepEdit(gpa, &cur, .{
            .start = @intCast(close_f),
            .end = @intCast(close_f),
            .new_text = " let x = 1;",
        });
        cur.deinit();
        cur = n;
        try std.testing.expect(cur.reused);
    }
    {
        const g_idx = findDeclBySymbolName(cur.module, "g").?;
        try std.testing.expect(Ast.declInteriorPending(cur.module.declarations.items[g_idx]) != 0);
    }

    // Edit 2: prepend a new top-level decl at offset 0 — that's a cross-
    // decl-boundary edit that falls back to parseFull.
    {
        const n = try stepEdit(gpa, &cur, .{
            .start = 0,
            .end = 0,
            .new_text = "fn prepended() {}\n",
        });
        cur.deinit();
        cur = n;
        // Either hot or fallback, but fallback is expected for this shape.
        // Either way, after a fallback (fresh parseFull) all biases are 0.
    }

    // Every bias must be zero now — either because edit 2 was a fresh
    // parse (fallback) or because hot-path correctly absorbed.
    for (cur.module.declarations.items) |d| {
        try std.testing.expectEqual(@as(i64, 0), Ast.declInteriorPending(d));
    }
}

test "IP-edge-02: round-trip edit + inverse leaves module matching full reparse" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}\nfn g() {}";
    var cur = try Incremental.parseFull(gpa, src);
    defer cur.deinit();

    // Forward: insert inside f.
    const close_f = std.mem.indexOfScalarPos(u8, cur.source, 0, '}').?;
    const after_ins = try stepEdit(gpa, &cur, .{
        .start = @intCast(close_f),
        .end = @intCast(close_f),
        .new_text = " let x = 1;",
    });
    cur.deinit();
    cur = after_ins;

    // Inverse: delete the same bytes we just inserted.
    const inserted_start: u32 = @intCast(close_f);
    const inserted_end: u32 = inserted_start + @as(u32, " let x = 1;".len);
    const after_del = try stepEdit(gpa, &cur, .{
        .start = inserted_start,
        .end = inserted_end,
        .new_text = "",
    });
    cur.deinit();
    cur = after_del;
    // Note: no extra `defer cur.deinit()` here — the outer defer at the
    // top of this test captures `cur` by reference and will deinit
    // whatever the variable holds at scope exit.

    try std.testing.expectEqualStrings(src, cur.source);

    // After round-trip the module shape must match a fresh parseFull.
    const source_z = try gpa.dupeZ(u8, cur.source);
    defer gpa.free(source_z);
    var oracle = try Incremental.parseFull(gpa, source_z);
    defer oracle.deinit();
    try std.testing.expectEqual(
        oracle.module.declarations.items.len,
        cur.module.declarations.items.len,
    );
}
