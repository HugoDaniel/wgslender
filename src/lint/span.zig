//! Expression source-span helpers for lint rules.
//!
//! `exprStart` / `exprEnd` recover the byte range an expression occupies in
//! source. They prefer the AST's populated `.span` and fall back to per-node
//! `.loc` tokens for nodes the parser left span-less, so a rule can point a
//! diagnostic at an expression without re-deriving positions itself.
//!
//! Rules that need to *observe* every node subscribe a `MultiVisitor.Listener`
//! (one shared traversal for all listener rules); rules that fold a subtree or
//! scan the symbol table keep their own `run` walk. See `MultiVisitor.zig` for
//! that taxonomy. This module is deliberately just the span math both styles
//! reuse.

const Ast = @import("../Ast.zig");

/// Best-effort start offset for an expression. Prefers `.span` when
/// populated; falls back to each node's `.loc` token.
pub fn exprStart(e: Ast.Expr) u32 {
    const s = e.span();
    if (s.start != s.end) return s.start;
    return switch (e) {
        .literal => |l| l.loc,
        .ident => |i| i.loc,
        .binary => |b| exprStart(b.left),
        .unary => |u| u.loc,
        .call => |c| c.loc,
        .index => |i| exprStart(i.base),
        .member => |m| exprStart(m.base),
        .paren => |p| exprStart(p.expr),
    };
}

/// Best-effort end offset (one past the last byte) for an expression.
/// Prefers `.span` when populated; otherwise derives from child locs plus
/// the token length of trailing identifiers / literals.
pub fn exprEnd(e: Ast.Expr) u32 {
    const s = e.span();
    if (s.start != s.end) return s.end;
    return switch (e) {
        .literal => |l| l.loc + @as(u32, @intCast(l.value.len)),
        .ident => |i| i.loc + @as(u32, @intCast(i.name.len)),
        .binary => |b| exprEnd(b.right),
        .unary => |u| exprEnd(u.operand),
        .call => |c| c.end_loc,
        .index => |i| i.end_loc,
        .member => |m| m.loc + @as(u32, @intCast(m.member_name.len)),
        .paren => |p| exprEnd(p.expr),
    };
}
