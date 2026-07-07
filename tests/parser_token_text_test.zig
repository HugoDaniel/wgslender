//! Numeric-literal text fidelity (Block 0.2).
//!
//! The `value` a front-end records on an `Ast.LiteralExpr` must be exactly the
//! source slice the lexer tokenized — `source[token.start..token.end]`. Before
//! Block 0.2 the parser re-derived number text with a hand-rolled
//! `scanNumberText` that could stop at a different boundary than the lexer on
//! edge cases (`1.e5`, `2.f`, hex floats). These cases pin the property that
//! the recorded value is the lexer's own byte-exact slice.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Lexer = wgslender.Lexer;
const Parser = wgslender.Parser;

/// Source slice of the first int/float literal token, per the lexer's stored
/// `Token.end` — the authoritative boundary this block defers to.
fn firstNumberSlice(source: [:0]const u8, tokens: *const std.MultiArrayList(Lexer.Token)) []const u8 {
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const ends = tokens.items(.end);
    for (tags, 0..) |t, i| {
        if (t == .int_literal or t == .float_literal) return source[starts[i]..ends[i]];
    }
    return "";
}

/// First `LiteralExpr` reachable from `e` (descends the postfix/operator chain
/// so a fixture like `2.fx`, parsed as `(2).fx`, still surfaces its literal).
fn firstLiteral(e: Ast.Expr) ?*Ast.LiteralExpr {
    return switch (e) {
        .literal => |l| l,
        .member => |m| firstLiteral(m.base),
        .index => |x| firstLiteral(x.base),
        .paren => |p| firstLiteral(p.expr),
        .unary => |u| firstLiteral(u.operand),
        .binary => |b| firstLiteral(b.left) orelse firstLiteral(b.right),
        .call => |c| if (c.args.items.len > 0) firstLiteral(c.args.items[0]) else null,
        .ident => null,
    };
}

const Case = struct { expr: []const u8, value: []const u8 };

const cases = [_]Case{
    .{ .expr = "2.f", .value = "2.f" },
    .{ .expr = "2.fx", .value = "2" }, // '.fx' is not a float suffix → int `2`, then `.fx`
    .{ .expr = "1.e5", .value = "1.e5" }, // dot-then-exponent, fractional digits omitted (§6.1.2)
    .{ .expr = "1.f", .value = "1.f" },
    .{ .expr = "0x1p4", .value = "0x1p4" },
    .{ .expr = "0x1.8p2", .value = "0x1.8p2" },
    .{ .expr = "1e5f", .value = "1e5f" },
};

test "parser: literal value is the lexer's byte-exact number slice" {
    const gpa = std.testing.allocator;
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const src_bytes = try std.fmt.allocPrint(a, "const X = {s};", .{c.expr});
        const source = try a.allocSentinel(u8, src_bytes.len, 0);
        @memcpy(source, src_bytes);

        var tokens = try Lexer.tokenize(a, source);
        var parser = try Parser.init(a, source, tokens);
        const module = try parser.parse();

        // Authoritative slice from the lexer's stored end.
        const lexer_slice = firstNumberSlice(source, &tokens);
        try std.testing.expectEqualStrings(c.value, lexer_slice);

        // The AST literal must record exactly that slice.
        try std.testing.expect(module.declarations.items.len == 1);
        const init_expr = module.declarations.items[0].@"const".initializer.?;
        const lit = firstLiteral(init_expr) orelse return error.NoLiteral;
        try std.testing.expectEqualStrings(c.value, lit.value);
    }
}
