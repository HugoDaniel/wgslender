//! Unit tests for `AstVisit.visitSubtreeStmt` / `visitSubtreeExpr` and the
//! `.add` / `.sub` mode switch on `AstVisit.Context`.
//!
//! These drive AstVisit *directly*, bypassing `Incremental.reparse`, so a
//! regression in mode-dispatch or the subtree entry points shows up here
//! without being masked by upstream full-parse fallbacks in the hot path.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const AstVisit = wgslender.AstVisit;
const Incremental = wgslender.Incremental;
const Parser = wgslender.Parser;

// =========================================================================
// Harness — pick subtrees out of a parsed module.
// =========================================================================

/// Find the n-th (0-indexed) non-empty function body in a module. Used to
/// reach into the stmts of a function without repeatedly re-writing the
/// navigation boilerplate.
fn nthFnBody(module: *const Ast.Module, n: usize) ?*Ast.CompoundStmt {
    var found: usize = 0;
    for (module.declarations.items) |d| {
        if (d != .function) continue;
        const body = d.function.body orelse continue;
        if (found == n) return body;
        found += 1;
    }
    return null;
}

/// Find a symbol by original name. Returns `.none` if missing.
fn findSymbol(module: *const Ast.Module, name: []const u8) Ast.SymbolIndex {
    for (module.symbols.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.original_name, name)) return @enumFromInt(@as(u32, @intCast(i)));
    }
    return .none;
}

fn useCountOf(module: *const Ast.Module, name: []const u8) u32 {
    const idx = findSymbol(module, name);
    if (!idx.isValid()) return 0;
    const i: usize = @intCast(@intFromEnum(idx));
    if (i >= module.use_counts.counts.len) return 0;
    return module.use_counts.counts[i];
}

/// Compare a SymbolIndex name against a literal string by looking up the
/// symbol table. Used to navigate decls whose `.name` is a `SymbolIndex`,
/// not a raw `[]const u8`.
fn symbolNameIs(module: *const Ast.Module, idx: Ast.SymbolIndex, name: []const u8) bool {
    if (!idx.isValid()) return false;
    const i: u32 = idx.index();
    if (i >= module.symbols.items.len) return false;
    return std.mem.eql(u8, module.symbols.items[i].original_name, name);
}

/// Construct a sub-mode Context against a parsed `Incremental.ReparseResult`.
/// The caller owns `errors` (empty); the allocator is the test allocator so
/// ArrayList backing for the Work stack lives outside the reparse arena.
fn subContext(
    gpa: std.mem.Allocator,
    base: *Incremental.ReparseResult,
    errors: *std.ArrayListUnmanaged(Parser.ParseError),
) AstVisit.Context {
    return .{
        .arena = gpa,
        .symbols = base.module.symbols.items,
        .scopes_in_order = &.{}, // sub-mode never walks the scope list
        .scope = base.module.scope,
        .errors = errors,
        .safety_budget = @max(64, base.cst.tokens.len * 2),
        .mode = .sub,
        .use_counts = &base.module.use_counts,
    };
}

fn addContext(
    gpa: std.mem.Allocator,
    base: *Incremental.ReparseResult,
    scope: *Ast.Scope,
    errors: *std.ArrayListUnmanaged(Parser.ParseError),
) AstVisit.Context {
    return .{
        .arena = gpa,
        .symbols = base.module.symbols.items,
        .scopes_in_order = &.{}, // scope cursor is positioned by caller; no enter/exit
        .scope = scope,
        .errors = errors,
        .safety_budget = @max(64, base.cst.tokens.len * 2),
        .mode = .add,
        .use_counts = &base.module.use_counts,
    };
}

/// Add-mode context variant that takes an explicit arena. U8/U9 exercise
/// the E0102 emission path which `allocPrint`s the diagnostic message
/// into `ctx.arena`; piping in a local ArenaAllocator keeps the test
/// allocator's leak detector happy.
fn addContextWithArena(
    arena: std.mem.Allocator,
    base: *Incremental.ReparseResult,
    scope: *Ast.Scope,
    errors: *std.ArrayListUnmanaged(Parser.ParseError),
) AstVisit.Context {
    return .{
        .arena = arena,
        .symbols = base.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = scope,
        .errors = errors,
        .safety_budget = @max(64, base.cst.tokens.len * 2),
        .mode = .add,
        .use_counts = &base.module.use_counts,
    };
}

// =========================================================================
// U1 — sub decrements each resolved ident once.
// =========================================================================

test "U1: sub-walk on `x + x + x` decrements symbols[x].use_count to 0" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1; const y = x + x + x;");
    defer base.deinit();

    // Pre: Pass 2 counted 3 uses of `x`.
    try std.testing.expectEqual(@as(u32, 3), useCountOf(base.module, "x"));

    // Reach into `y`'s initializer.
    var y_init: ?Ast.Expr = null;
    for (base.module.declarations.items) |d| {
        if (d == .@"const" and symbolNameIs(base.module, d.@"const".name, "y")) {
            y_init = d.@"const".initializer;
        }
    }
    const expr = y_init orelse return error.TestUnexpectedNull;

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "x"));
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

// =========================================================================
// U2 — sub ignores unresolved idents (ref == .none).
// =========================================================================

test "U2: sub-walk on ident with ref=.none does not panic or mutate symbols" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1; const y = x;");
    defer base.deinit();

    const x_uc_before = useCountOf(base.module, "x");

    // Hand-craft an unresolved ident expression with .none — mimics what
    // `Parser.reparseAnchor` produces before a targeted `add` pass.
    var dummy = Ast.IdentExpr{
        .name = "x",
        .ref = .none,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(x_uc_before, useCountOf(base.module, "x"));
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

// =========================================================================
// U3 — sub does not append to errors even when ref is stale.
// =========================================================================

test "U3: sub-walk never emits E0102 (no lookup runs)" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1; const y = x;");
    defer base.deinit();

    // Fabricate an ident whose pre-bound `ref` points at a symbol not
    // reachable from the current scope — `.add` would emit E0102 here,
    // `.sub` must stay silent because it never calls lookup.
    const x_idx = findSymbol(base.module, "x");
    var dummy = Ast.IdentExpr{ .name = "nope", .ref = x_idx };
    const expr: Ast.Expr = .{ .ident = &dummy };

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

// =========================================================================
// U4 — sub leaves the errors bucket intact.
// =========================================================================

test "U4: sub-walk preserves pre-existing errors" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1; const y = x;");
    defer base.deinit();

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    try errs.append(gpa, .{ .message = "seed", .pos = 7, .code = "E9999" });

    var ctx = subContext(gpa, &base, &errs);
    // Walk any subtree; here: `y`'s initializer.
    for (base.module.declarations.items) |d| {
        if (d == .@"const" and symbolNameIs(base.module, d.@"const".name, "y")) {
            _ = try AstVisit.visitSubtreeExpr(&ctx, d.@"const".initializer.?);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), errs.items.len);
    try std.testing.expectEqualStrings("seed", errs.items[0].message);
}

// =========================================================================
// U5 — add matches today's `visit` for a symbol-free subtree.
//
// Starting from a subtree with `ref = .none`, an add-walk must produce the
// same use_count delta as letting `parseFull` do Pass-2 on the whole file.
// =========================================================================

test "U5: add-walk on an ident_expr re-increments use_count after we zero it" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1; const y = x + x;");
    defer base.deinit();

    // Pre: x has 2 uses.
    try std.testing.expectEqual(@as(u32, 2), useCountOf(base.module, "x"));

    // Sub-walk removes them.
    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var sub_ctx = subContext(gpa, &base, &errs);
    for (base.module.declarations.items) |d| {
        if (d == .@"const" and symbolNameIs(base.module, d.@"const".name, "y")) {
            _ = try AstVisit.visitSubtreeExpr(&sub_ctx, d.@"const".initializer.?);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "x"));

    // Zero the refs on the subtree so add-walk has to re-resolve (mimics
    // a freshly parsed subtree from `Parser.reparseAnchor`).
    for (base.module.declarations.items) |d| {
        if (d == .@"const" and symbolNameIs(base.module, d.@"const".name, "y")) {
            zeroRefs(d.@"const".initializer.?);
        }
    }

    var add_ctx = addContext(gpa, &base, base.module.scope, &errs);
    for (base.module.declarations.items) |d| {
        if (d == .@"const" and symbolNameIs(base.module, d.@"const".name, "y")) {
            d.@"const".initializer = try AstVisit.visitSubtreeExpr(&add_ctx, d.@"const".initializer.?);
        }
    }
    try std.testing.expectEqual(@as(u32, 2), useCountOf(base.module, "x"));
}

/// Recursively reset `ref = .none` on every ident in an expression tree.
/// Mimics the ref state of a subtree freshly lowered from CST before any
/// add-walk binding pass has run.
fn zeroRefs(e: Ast.Expr) void {
    switch (e) {
        .ident => |i| i.ref = .none,
        .binary => |b| {
            zeroRefs(b.left);
            zeroRefs(b.right);
        },
        .unary => |u| zeroRefs(u.operand),
        .call => |c| {
            if (c.func) |f| zeroRefs(f);
            for (c.args.items) |a| zeroRefs(a);
        },
        .index => |ix| {
            zeroRefs(ix.base);
            zeroRefs(ix.idx);
        },
        .member => |m| zeroRefs(m.base),
        .paren => |p| zeroRefs(p.expr),
        .literal => {},
    }
}

// =========================================================================
// U6 — add-walk on a truly-unknown ident records no error.
//
// E0102 requires `lookupSymbol` to miss AND `lookupSymbolAnyLoc` to hit
// (the "later in scope" pattern). An ident whose name isn't declared
// anywhere fails both lookups, so no diagnostic is recorded. This test
// pins that negative behavior — Validator reports truly-undefined idents
// separately (E0100 family), not Pass-2.
// =========================================================================

test "U6: add-walk on a truly-unknown ident records no error (E0102 requires a later-in-scope hit)" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "const x = 1;");
    defer base.deinit();

    // Fabricate an ident referring to a name not declared in any scope.
    var dummy = Ast.IdentExpr{
        .loc = 42,
        .name = "nonexistent_symbol_name",
        .ref = .none,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = addContext(gpa, &base, base.module.scope, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    // Both lookups miss → no E0102. The ident's `ref` stays `.none` and
    // the error bucket stays empty — matches whole-module visit behavior
    // for truly undefined idents.
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
    try std.testing.expect(!dummy.ref.isValid());
}

// =========================================================================
// U7 — add scope-cursor respects the caller-supplied scope.
//
// The whole point of the add-mode subtree entry point is that callers
// position `ctx.scope` themselves (at the anchor's enclosing scope).
// This test proves that the walker DOES consult `ctx.scope` rather than
// hard-coding `module.scope`: it runs add-mode with `ctx.scope` set to
// a function-local block where a local `inner` is declared, and the
// subtree's reference to `inner` binds to that local symbol.
// =========================================================================

test "U7: add-walk at a nested block scope resolves to the block-local symbol" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let inner = 7; return inner; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const inner_idx = findSymbol(base.module, "inner");
    try std.testing.expect(inner_idx.isValid());

    // Pre: the existing `return inner;` already resolved inner.
    // use_count == 1.
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "inner"));

    // Extract the return-stmt's value expression, zero its ref to mimic a
    // freshly lowered subtree, then re-bind via add-walk starting from the
    // function body scope.
    const body = nthFnBody(base.module, 0) orelse return error.TestUnexpectedNull;
    var ret_expr: ?Ast.Expr = null;
    for (body.stmts.items) |s| {
        if (s == .@"return") ret_expr = s.@"return".value;
    }
    const expr = ret_expr orelse return error.TestUnexpectedNull;
    try std.testing.expect(expr == .ident);

    // Sub-walk first to remove the pre-existing use_count contribution.
    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var sub_ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&sub_ctx, expr);
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "inner"));

    // Zero the ref as if Parser.reparseAnchor just produced the node.
    expr.ident.ref = .none;

    // Walk scope-children to find the function body's block scope.
    // Structure: module → function-scope f → block scope (fn body).
    const fn_scope = blk: {
        for (base.module.scope.children.items) |c| {
            if (c.kind == .function) break :blk c;
        }
        break :blk null;
    } orelse return error.TestUnexpectedNull;
    // The fn's block scope is the first child of the function scope.
    const block_scope = if (fn_scope.children.items.len > 0)
        fn_scope.children.items[0]
    else
        fn_scope;

    var add_ctx = addContext(gpa, &base, block_scope, &errs);
    _ = try AstVisit.visitSubtreeExpr(&add_ctx, expr);

    // Add-walk resolved the ident against ctx.scope (the fn body block),
    // found `inner`, set the ref, and re-incremented use_count.
    try std.testing.expectEqual(inner_idx, expr.ident.ref);
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "inner"));
}

/// Walk `base.module.scope.children` to the function's block scope.
/// Mirrors the navigation in U7 and reuses it for U8/U9/U10.
fn fnBodyBlockScope(module: *const Ast.Module) ?*Ast.Scope {
    const fn_scope = blk: {
        for (module.scope.children.items) |c| {
            if (c.kind == .function) break :blk c;
        }
        break :blk null;
    } orelse return null;
    return if (fn_scope.children.items.len > 0)
        fn_scope.children.items[0]
    else
        fn_scope;
}

// =========================================================================
// U8 — add-walk emits E0102 on a real use-before-decl.
//
// Complement to U6. Here `lookupSymbol` misses (current_loc precedes the
// declaration) but `lookupSymbolAnyLoc` hits — the exact pattern that
// fires E0102 at `src/AstVisit.zig:253-257`. Also pins the side effects:
// `expr.ref` IS set to the late symbol, but `use_count` is NOT bumped
// on the error branch (the `if/else if` split in AstVisit skips the
// use_count increment when it takes the E0102 path).
// =========================================================================

test "U8: add-walk on a real use-before-decl records E0102 once, sets ref, does not bump use_count" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let z: i32 = 2; return z; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const z_idx = findSymbol(base.module, "z");
    try std.testing.expect(z_idx.isValid());
    // Pre: the existing `return z;` already resolved z → use_count == 1.
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));

    // Fabricate an ident with loc=1 (before any `let z` declaration).
    // `lookupSymbol` sees current_loc=1, member.loc ≫ 1 at block scope →
    // misses. `lookupSymbolAnyLoc` ignores loc → hits. E0102 fires.
    var dummy = Ast.IdentExpr{
        .loc = 1,
        .name = "z",
        .ref = .none,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    // The E0102 path both (a) allocPrints its message into ctx.arena and
    // (b) appends into `errs` via ctx.arena. Route both through one local
    // arena so teardown is a single arena.deinit() — using gpa for `errs`
    // and the arena for the visit would produce an allocator mismatch on
    // the backing ArrayList.
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;

    const block_scope = fnBodyBlockScope(base.module) orelse return error.TestUnexpectedNull;
    var ctx = addContextWithArena(arena, &base, block_scope, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(@as(usize, 1), errs.items.len);
    try std.testing.expectEqualStrings("E0102", errs.items[0].code);
    try std.testing.expectEqual(@as(u32, 1), errs.items[0].pos);

    // Ref is set to the late symbol (line 256).
    try std.testing.expectEqual(z_idx, dummy.ref);

    // use_count is NOT bumped on the E0102 branch — still 1 (the original
    // `return z` use). The add/miss branch does not increment.
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));
}

// =========================================================================
// U9 — add-walk emits E0102 once per occurrence of the before-decl ident.
//
// Two syntactically distinct `z` references inside the same subtree must
// produce two distinct E0102 entries at distinct byte positions. Proves
// the walker doesn't de-duplicate within a subtree.
// =========================================================================

test "U9: add-walk emits E0102 per occurrence for `z + z` where z is declared later" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let z: i32 = 2; return z; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    // Build `z + z` where both idents have loc < `let z`'s decl site.
    var lhs = Ast.IdentExpr{ .loc = 1, .name = "z", .ref = .none };
    var rhs = Ast.IdentExpr{ .loc = 3, .name = "z", .ref = .none };
    var bin = Ast.BinaryExpr{
        .loc = 1,
        .op = .add,
        .left = .{ .ident = &lhs },
        .right = .{ .ident = &rhs },
    };
    const expr: Ast.Expr = .{ .binary = &bin };

    // Two E0102 emissions → two allocPrints + two appends into `errs`,
    // all through `ctx.arena`. Route both through a single local arena.
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;

    const block_scope = fnBodyBlockScope(base.module) orelse return error.TestUnexpectedNull;
    var ctx = addContextWithArena(arena, &base, block_scope, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(@as(usize, 2), errs.items.len);
    try std.testing.expectEqualStrings("E0102", errs.items[0].code);
    try std.testing.expectEqualStrings("E0102", errs.items[1].code);
    try std.testing.expect(errs.items[0].pos != errs.items[1].pos);
}

// =========================================================================
// U10 — sub-walk never touches the errors bucket.
//
// Seed the bucket with unrelated entries. Sub-walk over a subtree whose
// idents carry pre-bound refs. The bucket must come out byte-identical
// to what was seeded: sub mode is explicitly documented as never
// emitting and never clearing errors (src/AstVisit.zig:259-270). Proves
// the non-interference directly, independent of the splice fixup.
// =========================================================================

// =========================================================================
// U-SUB-E0102-1 — sub-walk skips idents whose ref was set by the E0102
// branch.
//
// U8 pins the add-side invariant ("E0102 sets ref, doesn't bump
// use_count"); this pins the matching sub-side: an ident with
// `ref.isValid()` but `flags.use_count_incremented == false` — the
// exact shape the add-walk leaves behind on the E0102 branch — must
// NOT decrement the symbol's `use_count` on subtree removal.
// Regression test for the "sub-walk decrements idents the add-walk
// never bumped" bug.
// =========================================================================

test "U-SUB-E0102-1: sub-walk on an uncounted E0102 ident does not decrement use_count" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let z: i32 = 2; return z; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const z_idx = findSymbol(base.module, "z");
    try std.testing.expect(z_idx.isValid());
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));

    // Shape of an ident post-E0102-branch: `ref` points at the late
    // symbol, but `was_counted` is still false (add-walk intentionally
    // skipped the bump).
    var dummy = Ast.IdentExpr{
        .loc = 1,
        .name = "z",
        .ref = z_idx,
        .was_counted = false,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    // The sub-walk must gate on `was_counted`, not on `ref.isValid()`.
    // use_count stays at its pre-sub value.
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));
    // Non-interference: errors bucket untouched.
    try std.testing.expectEqual(@as(usize, 0), errs.items.len);
}

// =========================================================================
// U-SUB-E0102-2 — control: sub-walk on a properly-counted ident does
// decrement. Guards against a "just stop decrementing" non-fix.
// =========================================================================

test "U-SUB-E0102-2: sub-walk on a counted ident does decrement use_count" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let z: i32 = 2; return z; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const z_idx = findSymbol(base.module, "z");
    try std.testing.expect(z_idx.isValid());
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));

    // Shape of an ident post-successful-lookup: ref set AND
    // `was_counted` true. Simulates Pass 2 having bumped it.
    var dummy = Ast.IdentExpr{
        .loc = 100,
        .name = "z",
        .ref = z_idx,
        .was_counted = true,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    // Decremented by 1.
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "z"));
    // Defensive-hygiene check: the flag is cleared after decrement so a
    // second sub-walk on the same node would be a no-op.
    try std.testing.expect(!dummy.was_counted);

    // A second sub-walk is indeed a no-op (use_count stays at 0).
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "z"));
}

// =========================================================================
// U-ROUND-E0102 — add → sub on an E0102 ident is a net zero for the
// symbol's use_count.
//
// Round-trip invariant: the bit's true purpose. Drive the real add-walk
// on a fabricated loc=1 ident (forces E0102 via `lookupSymbolAnyLoc`),
// confirm it sets ref without bumping use_count AND leaves
// `use_count_incremented == false`; then run the sub-walk on the same
// node and confirm it too leaves use_count unchanged. This is the
// end-to-end pin that matches what `Incremental.reparse` exercises on
// every inverse-direction edit.
// =========================================================================

test "U-ROUND-E0102: add-walk on E0102 ident + sub-walk is a use_count no-op" {
    const gpa = std.testing.allocator;
    const src: [:0]const u8 = "fn f() -> i32 { let z: i32 = 2; return z; }";
    var base = try Incremental.parseFull(gpa, src);
    defer base.deinit();

    const z_idx = findSymbol(base.module, "z");
    try std.testing.expect(z_idx.isValid());
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));

    // Fresh ident, ref=.none, counted=false — exactly what
    // `Parser.reparseAnchor` hands to `visitSubtreeExpr`.
    var dummy = Ast.IdentExpr{
        .loc = 1,
        .name = "z",
        .ref = .none,
    };
    const expr: Ast.Expr = .{ .ident = &dummy };

    // Route the add-walk's allocPrint + error append through a local
    // arena (same technique as U8/U9).
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;

    const block_scope = fnBodyBlockScope(base.module) orelse return error.TestUnexpectedNull;
    var add_ctx = addContextWithArena(arena, &base, block_scope, &errs);
    _ = try AstVisit.visitSubtreeExpr(&add_ctx, expr);

    // Add-walk took the E0102 branch: emitted a diagnostic, set ref,
    // left `was_counted` false, and left use_count untouched.
    try std.testing.expectEqual(@as(usize, 1), errs.items.len);
    try std.testing.expectEqualStrings("E0102", errs.items[0].code);
    try std.testing.expectEqual(z_idx, dummy.ref);
    try std.testing.expect(!dummy.was_counted);
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));

    // Sub-walk must be a no-op for use_count.
    var sub_errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer sub_errs.deinit(gpa);
    var sub_ctx = subContext(gpa, &base, &sub_errs);
    _ = try AstVisit.visitSubtreeExpr(&sub_ctx, expr);
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "z"));
}

test "U10: sub-walk leaves a seeded errors bucket byte-identical after a subtree walk" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(gpa, "fn f() -> i32 { let a = 1; return a + a; }");
    defer base.deinit();

    var errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer errs.deinit(gpa);
    try errs.append(gpa, .{ .message = "seed-1", .pos = 7, .code = "E9999" });
    try errs.append(gpa, .{ .message = "seed-2", .pos = 13, .code = "E0102" });

    // Reach the fn's `return a + a;` value expression — idents here are
    // fully pre-bound by Pass 2.
    const body = nthFnBody(base.module, 0) orelse return error.TestUnexpectedNull;
    var ret_expr: ?Ast.Expr = null;
    for (body.stmts.items) |s| {
        if (s == .@"return") ret_expr = s.@"return".value;
    }
    const expr = ret_expr orelse return error.TestUnexpectedNull;

    var ctx = subContext(gpa, &base, &errs);
    _ = try AstVisit.visitSubtreeExpr(&ctx, expr);

    try std.testing.expectEqual(@as(usize, 2), errs.items.len);
    try std.testing.expectEqualStrings("seed-1", errs.items[0].message);
    try std.testing.expectEqualStrings("E9999", errs.items[0].code);
    try std.testing.expectEqual(@as(u32, 7), errs.items[0].pos);
    try std.testing.expectEqualStrings("seed-2", errs.items[1].message);
    try std.testing.expectEqualStrings("E0102", errs.items[1].code);
    try std.testing.expectEqual(@as(u32, 13), errs.items[1].pos);
}

// =========================================================================
// Attribute-arg Pass 2 binding — the gap closure (full-parse must bind &
// bump for `Ast.attributeArgsResolveSymbols(name) == true` and skip for
// the deny-list). Drives `parseFull` and inspects symbol use_counts so
// regressions in `visitAttributes` show up here directly, not behind a
// minify or DCE chain.
// =========================================================================

test "U-ATTR-1: @workgroup_size(WG_X) bumps WG_X.use_count to 1" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const WG_X: u32 = 16; @compute @workgroup_size(WG_X) fn main() {}",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "WG_X"));
}

test "U-ATTR-2: @workgroup_size(N, N, N) bumps N.use_count to 3 (multi-use single attr)" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const N: u32 = 8; @compute @workgroup_size(N, N, N) fn main() {}",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 3), useCountOf(base.module, "N"));
}

test "U-ATTR-3: nested @workgroup_size(N * 2) bumps N exactly once" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const N: u32 = 4; @compute @workgroup_size(N * 2) fn main() {}",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "N"));
}

test "U-ATTR-4: @group(BG) @binding(BG) on var bumps BG twice" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const BG: u32 = 0; @group(BG) @binding(BG) var<uniform> u: f32;",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 2), useCountOf(base.module, "BG"));
}

test "U-ATTR-5: @location on parameter binds at module scope" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const LOC: u32 = 3; @vertex fn f(@location(LOC) p: vec4f) -> @builtin(position) vec4f { return p; }",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "LOC"));
}

test "U-ATTR-6: @location on return type binds at module scope" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const RL: u32 = 1; @fragment fn f() -> @location(RL) vec4f { return vec4f(0.0); }",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "RL"));
}

test "U-ATTR-7: @align and @size on struct member each bump independently" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const A: u32 = 16; const SZ: u32 = 32; struct S { @align(A) @size(SZ) x: f32, y: i32 }",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "A"));
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "SZ"));
}

test "U-ATTR-8: @id(MY_ID) on override decl bumps MY_ID" {
    // `@id` takes a const-expression. MY_ID must be `const`, not
    // `override`. Pass 2's job here is to bind the IdentExpr in the
    // attribute to the `const MY_ID` symbol — independently of whether
    // Validator later approves the const-ness.
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const MY_ID: u32 = 7; @id(MY_ID) override x: f32;",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "MY_ID"));
}

test "U-ATTR-DENY-1: @interpolate(linear) does NOT bind a same-named user const" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const linear: f32 = 1.0; struct V { @location(0) @interpolate(linear) p: vec4f }",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "linear"));
}

test "U-ATTR-DENY-2: @builtin(vertex_index) does NOT bind a same-named user const" {
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const vertex_index: u32 = 5; struct V { @builtin(vertex_index) idx: u32 }",
    );
    defer base.deinit();
    try std.testing.expectEqual(@as(u32, 0), useCountOf(base.module, "vertex_index"));
}

// =========================================================================
// B.M1 tests (UseCounts side-table parity vs the deleted `Symbol.use_count`
// field) were removed in B.M5 — `module.use_counts` is now the only source.
// The U* suite above exercises every `.add`/`.sub` flow against it directly.
// =========================================================================

test "U-ATTR-PARITY: add-walk over an attr-arg subtree, then sub-walk, leaves use_count balanced" {
    // Drive the .add/.sub modes directly on an attr-arg ident expression.
    // After add-walk, WG_X.use_count == 1 (Pass 2 already bumped, then
    // visitSubtreeExpr in .add bumps a second time). After sub-walk,
    // it returns to 1 (decrement) — the flag-paired protocol guarantees
    // exactly one decrement per increment.
    const gpa = std.testing.allocator;
    var base = try Incremental.parseFull(
        gpa,
        "const WG_X: u32 = 16; @compute @workgroup_size(WG_X) fn main() {}",
    );
    defer base.deinit();

    // After parseFull (which runs Pass 2 with the new visitAttributes),
    // WG_X.use_count is already 1.
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "WG_X"));

    // Reach the @workgroup_size's first arg, an IdentExpr referencing WG_X.
    var attr_arg: ?Ast.Expr = null;
    for (base.module.declarations.items) |d| {
        if (d != .function) continue;
        for (d.function.attributes.items) |a| {
            if (!std.mem.eql(u8, a.name, "workgroup_size")) continue;
            if (a.args.items.len > 0) attr_arg = a.args.items[0];
        }
    }
    const expr = attr_arg orelse return error.TestUnexpectedNull;

    // Add-walk: bumps WG_X to 2.
    var add_errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer add_errs.deinit(gpa);
    var add_ctx: AstVisit.Context = .{
        .arena = gpa,
        .symbols = base.module.symbols.items,
        .scopes_in_order = &.{},
        .scope = base.module.scope,
        .errors = &add_errs,
        .safety_budget = @max(64, base.cst.tokens.len * 2),
        .mode = .add,
        .use_counts = &base.module.use_counts,
    };
    _ = try AstVisit.visitSubtreeExpr(&add_ctx, expr);
    try std.testing.expectEqual(@as(u32, 2), useCountOf(base.module, "WG_X"));

    // Sub-walk: must decrement exactly once (flag-paired) → back to 1.
    var sub_errs: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    defer sub_errs.deinit(gpa);
    var sub_ctx = subContext(gpa, &base, &sub_errs);
    _ = try AstVisit.visitSubtreeExpr(&sub_ctx, expr);
    try std.testing.expectEqual(@as(u32, 1), useCountOf(base.module, "WG_X"));
}
