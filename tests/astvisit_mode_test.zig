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
    return module.symbols.items[@intCast(@intFromEnum(idx))].use_count;
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
    // `CstLower.lowerSubtree` produces before a targeted `add` pass.
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
    // a freshly lowered subtree from `CstLower.lowerSubtree`).
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
// U6 — add emits E0102 when an ident misresolves.
// =========================================================================

test "U6: add-walk on an unresolvable ident records E0102 once" {
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

    // lookupSymbol returns null AND lookupSymbolAnyLoc returns null → no
    // E0102 (unknown ident, not a before-decl). The ident's `ref` stays
    // `.none`, and no diagnostic is recorded — this matches today's
    // whole-module visit behavior for truly undefined idents.
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

    // Zero the ref as if CstLower.lowerSubtree just produced the node.
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
