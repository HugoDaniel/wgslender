//! Structural precedence pins for the Parser (Block 1.1).
//!
//! The minifier's printer is a *flat* printer: it emits binary operands and
//! operator tokens in tree order and relies on explicit `.paren` nodes for
//! grouping — it does NOT re-parenthesize from precedence. So `add(a, mul(b,c))`
//! and the mis-parse `mul(add(a,b), c)` both print as `a+b*c`. Golden-text
//! snapshots therefore catch a wrong operator *value* or a dropped paren, but
//! NOT a wrong precedence *order*. These tests assert the AST tree shape
//! directly (printer-independent), so swapping two precedence levels — the
//! primary risk when collapsing the precedence functions into one table — fails
//! loudly here.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const BinaryOp = Ast.BinaryOp;

/// Parse `const q = <expr>;` and return the initializer expression.
fn constInit(r: *const Incremental.ReparseResult) !Ast.Expr {
    for (r.module.declarations.items) |d| {
        if (d != .@"const") continue;
        return d.@"const".initializer orelse error.NoInitializer;
    }
    return error.NoConstDecl;
}

fn expectBin(expr: Ast.Expr, op: BinaryOp) !*Ast.BinaryExpr {
    try std.testing.expect(expr == .binary);
    try std.testing.expectEqual(op, expr.binary.op);
    return expr.binary;
}

fn expectIdent(expr: Ast.Expr, name: []const u8) !void {
    try std.testing.expect(expr == .ident);
    try std.testing.expectEqualStrings(name, expr.ident.name);
}

test "precedence: multiplicative binds tighter than additive (a+b*c)" {
    var r = try Incremental.parseFull(std.testing.allocator, "const q = a + b * c;\n");
    defer r.deinit();
    // a + (b * c): root is add, right operand is the mul.
    const root = try expectBin(try constInit(&r), .add);
    try expectIdent(root.left, "a");
    const rhs = try expectBin(root.right, .mul);
    try expectIdent(rhs.left, "b");
    try expectIdent(rhs.right, "c");
}

test "precedence: additive is looser than multiplicative (a*b+c)" {
    var r = try Incremental.parseFull(std.testing.allocator, "const q = a * b + c;\n");
    defer r.deinit();
    // (a * b) + c: root is add, left operand is the mul.
    const root = try expectBin(try constInit(&r), .add);
    const lhs = try expectBin(root.left, .mul);
    try expectIdent(lhs.left, "a");
    try expectIdent(lhs.right, "b");
    try expectIdent(root.right, "c");
}

test "precedence: same-level operators are left-associative (a-b-c)" {
    var r = try Incremental.parseFull(std.testing.allocator, "const q = a - b - c;\n");
    defer r.deinit();
    // (a - b) - c, not a - (b - c): the LEFT operand is the nested sub.
    const root = try expectBin(try constInit(&r), .sub);
    const lhs = try expectBin(root.left, .sub);
    try expectIdent(lhs.left, "a");
    try expectIdent(lhs.right, "b");
    try expectIdent(root.right, "c");
}

test "precedence: full ladder, one op per level, right-nested" {
    var r = try Incremental.parseFull(
        std.testing.allocator,
        "const q = a || b && c | d ^ e & f == g < h << i + j * k;\n",
    );
    defer r.deinit();
    // Every operator to the right binds tighter, so the right spine descends
    // the precedence ladder exactly once per level: || < && < | < ^ < & < == <
    // < < << < + < *. A swapped level reorders this spine and fails here.
    const ladder = [_]BinaryOp{ .logical_or, .logical_and, .@"or", .xor, .@"and", .eq, .lt, .shl, .add, .mul };
    var expr = try constInit(&r);
    for (ladder) |op| {
        const node = try expectBin(expr, op);
        expr = node.right; // descend the right spine
    }
    // Bottom of the ladder: the mul's operands are the last two idents.
    try expectIdent(expr, "k");
}

test "precedence: template-arg additive over multiplicative (N+1*2)" {
    var r = try Incremental.parseFull(
        std.testing.allocator,
        "const N = 3;\nvar<private> x: array<f32, N + 1 * 2>;\n",
    );
    defer r.deinit();
    // Find the array size expression: N + (1 * 2).
    var size: ?Ast.Expr = null;
    for (r.module.declarations.items) |d| {
        if (d != .@"var") continue;
        if (d.@"var".typ) |t| if (t == .array) {
            size = t.array.size;
        };
    }
    const root = try expectBin(size orelse return error.NoArraySize, .add);
    try expectIdent(root.left, "N");
    const rhs = try expectBin(root.right, .mul);
    try std.testing.expect(rhs.left == .literal);
    try std.testing.expect(rhs.right == .literal);
}

test "precedence: explicit parens invert grouping in template arg ((N+1)*2)" {
    var r = try Incremental.parseFull(
        std.testing.allocator,
        "const N = 3;\nvar<private> x: array<f32, (N + 1) * 2>;\n",
    );
    defer r.deinit();
    var size: ?Ast.Expr = null;
    for (r.module.declarations.items) |d| {
        if (d != .@"var") continue;
        if (d.@"var".typ) |t| if (t == .array) {
            size = t.array.size;
        };
    }
    // (N + 1) * 2: root is mul, left is a paren wrapping the add.
    const root = try expectBin(size orelse return error.NoArraySize, .mul);
    try std.testing.expect(root.left == .paren);
    _ = try expectBin(root.left.paren.expr, .add);
}
