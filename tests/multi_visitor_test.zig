//! Unit tests for `src/lint/MultiVisitor.zig` — the multi-listener AST
//! walker that fans one traversal out to N subscribers.

const std = @import("std");
const wgslender = @import("wgslender");
const Allocator = std.mem.Allocator;
const Ast = wgslender.Ast;
const MultiVisitor = wgslender.MultiVisitor;

// =========================================================================
// Test helpers
// =========================================================================

const Counters = struct {
    exprs: u32 = 0,
    stmts: u32 = 0,
    decls: u32 = 0,

    fn onExpr(opaque_ctx: *anyopaque, _: Ast.Expr) Allocator.Error!void {
        const self: *Counters = @ptrCast(@alignCast(opaque_ctx));
        self.exprs += 1;
    }

    fn onStmt(opaque_ctx: *anyopaque, _: Ast.Stmt) Allocator.Error!void {
        const self: *Counters = @ptrCast(@alignCast(opaque_ctx));
        self.stmts += 1;
    }

    fn onDecl(opaque_ctx: *anyopaque, _: Ast.Decl) Allocator.Error!void {
        const self: *Counters = @ptrCast(@alignCast(opaque_ctx));
        self.decls += 1;
    }
};

const ExprList = struct {
    list: std.ArrayListUnmanaged(Ast.Expr) = .empty,

    fn record(opaque_ctx: *anyopaque, e: Ast.Expr) Allocator.Error!void {
        const self: *ExprList = @ptrCast(@alignCast(opaque_ctx));
        try self.list.append(std.testing.allocator, e);
    }
};

fn parseForTest(alloc: Allocator, source: [:0]const u8) !*Ast.Module {
    const tokens = try wgslender.Lexer.tokenize(alloc, source);
    var parser = try wgslender.Parser.init(alloc, source, tokens);
    return try parser.parse();
}

// =========================================================================
// Tests
// =========================================================================

test "MultiVisitor: empty listeners is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseForTest(arena.allocator(), "fn f() { let a: f32 = 1.0 + 2.0; }");
    try MultiVisitor.walk(arena.allocator(), module, &.{});
}

test "MultiVisitor: single listener counts every expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseForTest(arena.allocator(), "fn f() { let a: f32 = 1.0 + 2.0; }");

    var counters = Counters{};
    try MultiVisitor.walk(arena.allocator(), module, &.{
        .{ .ctx = &counters, .on_expr = Counters.onExpr },
    });

    // 1.0 + 2.0 → binary, 1.0, 2.0 = 3 expressions.
    try std.testing.expectEqual(@as(u32, 3), counters.exprs);
    try std.testing.expectEqual(@as(u32, 0), counters.stmts);
    try std.testing.expectEqual(@as(u32, 0), counters.decls);
}

test "MultiVisitor: two listeners receive identical event streams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseForTest(
        arena.allocator(),
        "fn f(x: i32) -> i32 { if (x > 0) { return x + 1; } else { return -x; } }",
    );

    var a = Counters{};
    var b = Counters{};
    try MultiVisitor.walk(arena.allocator(), module, &.{
        .{ .ctx = &a, .on_expr = Counters.onExpr, .on_stmt = Counters.onStmt, .on_decl = Counters.onDecl },
        .{ .ctx = &b, .on_expr = Counters.onExpr, .on_stmt = Counters.onStmt, .on_decl = Counters.onDecl },
    });

    try std.testing.expectEqual(a.exprs, b.exprs);
    try std.testing.expectEqual(a.stmts, b.stmts);
    try std.testing.expectEqual(a.decls, b.decls);
    try std.testing.expect(a.exprs > 0);
    try std.testing.expect(a.stmts > 0);
    try std.testing.expect(a.decls > 0);
}

test "MultiVisitor: decl + stmt + expr listeners fire on the right node kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseForTest(
        arena.allocator(),
        "fn f() { var x: i32 = 0; x = x + 1; }",
    );

    var counters = Counters{};
    try MultiVisitor.walk(arena.allocator(), module, &.{
        .{ .ctx = &counters, .on_expr = Counters.onExpr, .on_stmt = Counters.onStmt, .on_decl = Counters.onDecl },
    });

    try std.testing.expect(counters.decls >= 1); // function decl + nested var decl (via decl_stmt)
    try std.testing.expect(counters.stmts >= 2); // var decl_stmt, assign stmt
    try std.testing.expect(counters.exprs >= 4); // 0, x (left), x (right), 1, x+1 binary
}

test "MultiVisitor: expression visitation order matches walk.zig (left-then-right)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const k: i32 = 1 + 2;";
    const module = try parseForTest(arena.allocator(), source);

    var seen = ExprList{};
    defer seen.list.deinit(std.testing.allocator);
    try MultiVisitor.walk(arena.allocator(), module, &.{
        .{ .ctx = &seen, .on_expr = ExprList.record },
    });

    // Order: parent first, then left child, then right child.
    try std.testing.expectEqual(@as(usize, 3), seen.list.items.len);
    try std.testing.expect(seen.list.items[0] == .binary);
    try std.testing.expect(seen.list.items[1] == .literal);
    try std.testing.expect(seen.list.items[2] == .literal);
    try std.testing.expectEqualStrings("1", seen.list.items[1].literal.value);
    try std.testing.expectEqualStrings("2", seen.list.items[2].literal.value);
}

test "MultiVisitor: const_assert expr is walked, struct/alias have no exprs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseForTest(
        arena.allocator(),
        "struct S { x: i32 } alias A = i32; const_assert 1 < 2;",
    );

    var counters = Counters{};
    try MultiVisitor.walk(arena.allocator(), module, &.{
        .{ .ctx = &counters, .on_expr = Counters.onExpr, .on_decl = Counters.onDecl },
    });

    try std.testing.expectEqual(@as(u32, 3), counters.decls);
    // const_assert's `1 < 2` is a binary expression with two literal operands → 3 exprs.
    try std.testing.expectEqual(@as(u32, 3), counters.exprs);
}
