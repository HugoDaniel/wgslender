//! Incremental splice retirement tests.
//!
//! The incremental hot path is append-only: re-lowering a `compound_stmt`
//! or `decl_stmt` anchor leaves the detached subtree's declaration symbols
//! in `module.symbols` with `use_count == 0`. Those tombstones must be
//! marked `is_retired` so every reporting surface filters them out, and a
//! forced full parse (coalescing) must reclaim them.
//!
//! `is_retired` is read through `@hasField` so this suite compiles (and
//! fails on behaviour) before the flag exists: the helpers below are
//! compile-time gated, and the assertions are genuine test failures rather
//! than a missing-field compile error.

const std = @import("std");
const wgslender = @import("wgslender");
const Handler = @import("Handler");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const Linter = wgslender.Linter;

const lint_opts = Linter.Options{ .extends = &.{"@wgslender/recommended"} };

// =========================================================================
// Retirement accessors (compile-time gated on the A2 flag)
// =========================================================================

fn isRetired(module: *const Ast.Module, idx: usize) bool {
    if (idx >= module.symbols.items.len) return false;
    const flags = module.symbols.items[idx].flags;
    if (comptime @hasField(Ast.Symbol.Flags, "is_retired")) {
        return @field(flags, "is_retired");
    }
    return false;
}

fn countRetired(module: *const Ast.Module) usize {
    var n: usize = 0;
    for (module.symbols.items, 0..) |_, i| {
        if (isRetired(module, i)) n += 1;
    }
    return n;
}

fn symbolByName(module: *const Ast.Module, name: []const u8) ?usize {
    return symbolByOccurrence(module, name, 0);
}

fn symbolByOccurrence(module: *const Ast.Module, name: []const u8, occurrence: usize) ?usize {
    var seen: usize = 0;
    for (module.symbols.items, 0..) |sym, i| {
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        if (seen == occurrence) return i;
        seen += 1;
    }
    return null;
}

fn expectRetired(module: *const Ast.Module, idx: usize, msg: []const u8) !void {
    if (!isRetired(module, idx)) {
        std.debug.print("expected symbol {d} ('{s}') to be retired ({s})\n", .{
            idx, module.symbols.items[idx].original_name, msg,
        });
        return error.SymbolNotRetired;
    }
}

fn expectActive(module: *const Ast.Module, idx: usize, msg: []const u8) !void {
    if (isRetired(module, idx)) {
        std.debug.print("expected symbol {d} ('{s}') to stay active ({s})\n", .{
            idx, module.symbols.items[idx].original_name, msg,
        });
        return error.SymbolRetiredUnexpectedly;
    }
}

// =========================================================================
// Diagnostic snapshot oracle
//
// One canonical line per diagnostic (validator + lint), sorted. Multiset
// equality is the point: a retired tombstone duplicates the active
// symbol's message at the same location, so a set comparison would hide it.
// =========================================================================

const Snapshot = []const []u8;

fn appendSnapshotLine(
    gpa: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    entry: wgslender.Diagnostic.Entry,
) !void {
    const line = try std.fmt.allocPrint(gpa, "{s}|{d}:{d}-{d}:{d}|{s}", .{
        entry.code,
        entry.range.start.line,
        entry.range.start.column,
        entry.range.end.line,
        entry.range.end.column,
        entry.message,
    });
    try out.append(gpa, line);
}

fn snapshotLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn snapshotModule(
    gpa: std.mem.Allocator,
    module: *Ast.Module,
    parse_errors: []const wgslender.Parser.ParseError,
    lint_options: Linter.Options,
) !Snapshot {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var analysis = try wgslender.Validator.analyze(arena, module, .{});
    wgslender.Parser.mergeErrorsInto(parse_errors, analysis.diagnostics, arena);

    var lint = try Linter.run(gpa, &analysis, lint_options);
    defer lint.deinit(gpa);

    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| gpa.free(line);
        lines.deinit(gpa);
    }
    for (analysis.diagnostics.items()) |entry| try appendSnapshotLine(gpa, &lines, entry);
    for (lint.diagnostics.items()) |entry| try appendSnapshotLine(gpa, &lines, entry);
    std.mem.sort([]u8, lines.items, {}, snapshotLessThan);
    return try lines.toOwnedSlice(gpa);
}

fn freeSnapshot(gpa: std.mem.Allocator, snap: Snapshot) void {
    for (snap) |line| gpa.free(line);
    gpa.free(snap);
}

fn expectSnapshotsEqual(got: Snapshot, oracle: Snapshot) !void {
    if (got.len != oracle.len) {
        std.debug.print("diagnostic count mismatch: incremental={d} fresh={d}\n", .{ got.len, oracle.len });
        for (got) |line| std.debug.print("  incremental {s}\n", .{line});
        for (oracle) |line| std.debug.print("  fresh       {s}\n", .{line});
        return error.DiagnosticCountMismatch;
    }
    for (got, oracle) |g, o| {
        if (!std.mem.eql(u8, g, o)) {
            std.debug.print("diagnostic mismatch:\n  incremental {s}\n  fresh       {s}\n", .{ g, o });
            return error.DiagnosticMismatch;
        }
    }
}

fn snapshotContainsCode(snap: Snapshot, code: []const u8) bool {
    for (snap) |line| {
        if (std.mem.startsWith(u8, line, code)) return true;
    }
    return false;
}

fn snapshotContains(snap: Snapshot, needle: []const u8) bool {
    for (snap) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn expectIncrementalMatchesFresh(
    gpa: std.mem.Allocator,
    state: *Incremental.ReparseResult,
) !void {
    const got = try snapshotModule(gpa, state.module, state.errors, lint_opts);
    defer freeSnapshot(gpa, got);

    var oracle = try Incremental.parseFull(gpa, state.source);
    defer oracle.deinit();
    const fresh = try snapshotModule(gpa, oracle.module, oracle.errors, lint_opts);
    defer freeSnapshot(gpa, fresh);

    try expectSnapshotsEqual(got, fresh);
}

// =========================================================================
// 1. Non-zero comment burst retires detached locals without W0001
// =========================================================================

test "non-zero comment burst retires detached locals without W0001" {
    const gpa = std.testing.allocator;
    const text = "// note";
    const src: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {
        \\    let a: i32 = 1;
        \\    let b: i32 = a + 1;
        \\
        \\    _ = b;
        \\}
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Insert at the start of the blank body line, one character at a time.
    // The first `/` is a parse error (full-parse fallback); from the second
    // character on the edit is valid trivia and takes the compound splice.
    const blank_line = std.mem.indexOf(u8, src, "\n\n").?;
    const insert_at: u32 = @intCast(blank_line + 1);

    for (text, 0..) |_, i| {
        const next = try Incremental.reparse(gpa, &state, .{
            .start = insert_at + @as(u32, @intCast(i)),
            .end = insert_at + @as(u32, @intCast(i)),
            .new_text = text[i..][0..1],
        });
        state.deinit();
        state = next;

        try expectIncrementalMatchesFresh(gpa, &state);

        const snap = try snapshotModule(gpa, state.module, state.errors, lint_opts);
        defer freeSnapshot(gpa, snap);
        if (snapshotContainsCode(snap, "W0001")) {
            for (snap) |line| std.debug.print("  unexpected {s}\n", .{line});
            return error.FalseUnusedWarning;
        }
    }
}

// =========================================================================
// 2. Compound retirement covers nested blocks and for-init declarations
// =========================================================================

test "compound retirement covers nested blocks and for-init declarations" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\const K: i32 = 7;
        \\struct S { m: i32 }
        \\fn f(p: i32) -> i32 {
        \\    if p > 0 {
        \\        let nested: i32 = p;
        \\        { let deep: i32 = nested; _ = deep; }
        \\    }
        \\    for (var i: i32 = 0; i < p; i = i + 1) {
        \\        let loop_local: i32 = i;
        \\        _ = loop_local;
        \\    }
        \\    return K;
        \\}
        \\
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const module = state.module;

    const old_nested = symbolByName(module, "nested").?;
    const old_deep = symbolByName(module, "deep").?;
    const old_i = symbolByName(module, "i").?;
    const old_loop_local = symbolByName(module, "loop_local").?;
    const param = symbolByName(module, "p").?;
    const module_const = symbolByName(module, "K").?;
    const struct_member = symbolByName(module, "m").?;
    const symbols_before = module.symbols.items.len;

    // Insert one space before `return K;` — a non-zero-delta edit inside the
    // function body. The anchor is the outer compound, so the re-lower
    // appends fresh copies of every declaration in the detached subtree.
    const ret_at: u32 = @intCast(std.mem.indexOf(u8, src, "return K;").?);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = ret_at,
        .end = ret_at,
        .new_text = " ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    try expectRetired(state.module, old_nested, "nested if-body declaration");
    try expectRetired(state.module, old_deep, "nested bare-block declaration");
    try expectRetired(state.module, old_i, "for-init declaration");
    try expectRetired(state.module, old_loop_local, "for-body declaration");
    try std.testing.expectEqual(@as(usize, 4), countRetired(state.module));

    // Out-of-subtree symbols stay active.
    try expectActive(state.module, param, "function parameter");
    try expectActive(state.module, module_const, "module-level const reference");
    try expectActive(state.module, struct_member, "struct member");

    // Fresh copies are active and the growth is exactly one per declaration.
    try std.testing.expectEqual(symbols_before + 4, state.module.symbols.items.len);
    for (symbols_before..state.module.symbols.items.len) |i| {
        try expectActive(state.module, i, "fresh declaration copy");
    }
}

// =========================================================================
// 3. Duplicate declarations are all retired
// =========================================================================

test "duplicate declarations are all retired" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() -> i32 {
        \\    let dup: i32 = 1;
        \\    let dup: i32 = 2;
        \\    return 0;
        \\}
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // `Parser.declareSymbol` overwrites the same-name scope entry while
    // still appending its symbol. The first duplicate is absent from
    // `Scope.members` but present in the detached AST — it must still be
    // retired.
    const first = symbolByOccurrence(state.module, "dup", 0).?;
    const second = symbolByOccurrence(state.module, "dup", 1).?;
    try std.testing.expect(first != second);

    // Replace the whole body with a clean one: the OLD subtree still holds
    // both duplicate declarations, while the NEW subtree parses without a
    // redeclaration error, so the compound splice stays on the hot path.
    const body_start: u32 = @intCast(std.mem.indexOfScalar(u8, src, '{').?);
    const body_end: u32 = @intCast(std.mem.lastIndexOfScalar(u8, src, '}').? + 1);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = body_start,
        .end = body_end,
        .new_text = "{ return 0; }",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    try expectRetired(state.module, first, "first duplicate declaration");
    try expectRetired(state.module, second, "second duplicate declaration");
    try std.testing.expectEqual(@as(usize, 2), countRetired(state.module));
}

// =========================================================================
// 4. Decl splice retires exactly the old declaration
// =========================================================================

test "decl splice retires exactly the old declaration" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() -> i32 { let x: i32 = 1; return x; }
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const old_x = symbolByName(state.module, "x").?;
    const name_at: u32 = @intCast(std.mem.indexOf(u8, src, "x: i32").?);

    const next = try Incremental.reparse(gpa, &state, .{
        .start = name_at,
        .end = name_at + 1,
        .new_text = "y",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    try std.testing.expectEqual(@as(usize, 1), countRetired(state.module));
    try expectRetired(state.module, old_x, "old declaration in the decl-stmt slot");

    const new_y = symbolByName(state.module, "y") orelse return error.MissingFreshSymbol;
    try expectActive(state.module, new_y, "fresh declaration");
}

// =========================================================================
// 5. Symbol-free splice retires nothing
// =========================================================================

test "symbol-free splice retires nothing" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { return 0; }";

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const symbols_before = state.module.symbols.items.len;

    const lit_at: u32 = @intCast(std.mem.indexOf(u8, src, "0").?);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = lit_at,
        .end = lit_at + 1,
        .new_text = "42",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));
    try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
}

// =========================================================================
// 6. Struct members and external references are not retired
// =========================================================================

test "struct members and external references are not retired" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 =
        \\struct S { member: i32 }
        \\const MODULE_CONST: i32 = 1;
        \\fn f(param: i32) -> i32 {
        \\    let local_a: i32 = param;
        \\    let local_b: i32 = MODULE_CONST;
        \\    let s: S = S(local_a);
        \\    return s.member;
        \\}
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const local_a = symbolByName(state.module, "local_a").?;
    const local_b = symbolByName(state.module, "local_b").?;
    const local_s = symbolByName(state.module, "s").?;
    const param = symbolByName(state.module, "param").?;
    const fn_sym = symbolByName(state.module, "f").?;
    const module_const = symbolByName(state.module, "MODULE_CONST").?;
    const struct_sym = symbolByName(state.module, "S").?;
    const member_sym = symbolByName(state.module, "member").?;

    const ret_at: u32 = @intCast(std.mem.indexOf(u8, src, "return s.member;").?);
    const next = try Incremental.reparse(gpa, &state, .{
        .start = ret_at,
        .end = ret_at,
        .new_text = " ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    try expectRetired(state.module, local_a, "detached local");
    try expectRetired(state.module, local_b, "detached local");
    try expectRetired(state.module, local_s, "detached local");
    try std.testing.expectEqual(@as(usize, 3), countRetired(state.module));

    try expectActive(state.module, param, "parameter declared outside the block");
    try expectActive(state.module, fn_sym, "enclosing function");
    try expectActive(state.module, module_const, "module-level const");
    try expectActive(state.module, struct_sym, "struct declaration");
    try expectActive(state.module, member_sym, "struct member");
}

// =========================================================================
// 7. Coalescing reclaims retired symbols
// =========================================================================

test "semantic hot-edit long tail resets retirement at coalescing" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let a: i32 = 1; return a; }";

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const base_symbols = state.module.symbols.items.len;
    const keyword_at: u32 = @intCast(std.mem.indexOf(u8, src, "let a").?);
    try std.testing.expectEqualStrings("let", src[keyword_at..][0..3]);

    // Each edit replaces a single declaration; D_i == 1. Symbol growth is
    // therefore exactly one per hot edit and one tombstone accumulates.
    for (0..Incremental.HOT_EDIT_COALESCE_MAX) |i| {
        const replacement = if (i % 2 == 0) "var" else "let";
        const next = try Incremental.reparse(gpa, &state, .{
            .start = keyword_at,
            .end = keyword_at + 3,
            .new_text = replacement,
        });
        state.deinit();
        state = next;

        try std.testing.expect(state.reused);
        try std.testing.expectEqual(base_symbols + i + 1, state.module.symbols.items.len);
        try std.testing.expectEqual(i + 1, countRetired(state.module));
    }

    // The 257th edit trips the edit-count watermark and forces parseFull:
    // append-only growth and every tombstone disappear together.
    const replacement = if (Incremental.HOT_EDIT_COALESCE_MAX % 2 == 0) "var" else "let";
    const coalesced = try Incremental.reparse(gpa, &state, .{
        .start = keyword_at,
        .end = keyword_at + 3,
        .new_text = replacement,
    });
    state.deinit();
    state = coalesced;

    try std.testing.expect(!state.reused);
    try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));

    var oracle = try Incremental.parseFull(gpa, state.source);
    defer oracle.deinit();
    try std.testing.expectEqual(oracle.module.symbols.items.len, state.module.symbols.items.len);
}
