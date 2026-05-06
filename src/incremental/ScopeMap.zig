//! CST↔AST scope-pairing helpers for the incremental hot path.
//!
//! A `ReparseResult` carries a side-table mapping every scope-opener
//! CST node (fn_decl, compound_stmt, for_stmt) to the AST scope it
//! corresponds to. This module owns the helpers that build and query
//! that map:
//!
//!   - `buildScopeForCstNodeMap` populates the map after a full parse,
//!     and after the compound/decl-stmt splice paths, by zipping a DFS
//!     of CST openers with a DFS of non-root AST scopes.
//!   - `scopeAtCstNode` walks a node's CST ancestor chain to find the
//!     nearest registered scope, falling back to `module.scope` at the
//!     root.
//!
//! Both front-ends (Parser and CstLower) push scopes in the exact order
//! the CST opens scope-bearing nodes, which is what makes the index-zip
//! correct.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Cst = @import("../Cst.zig");
const Incremental = @import("../Incremental.zig");
const constants = @import("../constants.zig");

/// Walk a CST node's ancestor chain until we find one that has a
/// registered scope in `result.scope_for_cst_node`, and return that scope.
/// Falls back to `result.module.scope` if none is found (e.g., when the
/// map is empty because the caller bypassed `buildScopeForCstNodeMap`).
///
/// Used by the add/sub hot path to position `AstVisit.Context.scope` at
/// the anchor's enclosing scope before an add-walk.
pub fn scopeAtCstNode(result: *const Incremental.ReparseResult, node: Cst.NodeIndex) *Ast.Scope {
    std.debug.assert(!result.moved);
    var cur = node;
    for (0..constants.max_tree_walk_iterations) |_| {
        if (result.scope_for_cst_node.get(@intFromEnum(cur))) |s| return s;
        const n = result.cst.getNode(cur);
        if (n.parent == cur) return result.module.scope; // reached the root
        cur = n.parent;
    } else unreachable;
}

/// True when this CST kind opens an AST scope during lowering. Kept in
/// lockstep with the `pushScope` call sites in `Parser` and `CstLower`.
fn isScopeOpener(k: Cst.Kind) bool {
    return switch (k) {
        .fn_decl, .compound_stmt, .for_stmt => true,
        else => false,
    };
}

fn collectCstOpeners(
    gpa: Allocator,
    cst: *const Cst.Tree,
    node: Cst.NodeIndex,
    out: *std.ArrayList(Cst.NodeIndex),
) error{OutOfMemory}!void {
    const n = cst.getNode(node);
    if (isScopeOpener(n.kind)) try out.append(gpa, node);
    for (cst.children[n.first_child .. n.first_child + n.child_count]) |el| {
        if (el.asNode()) |child| {
            try collectCstOpeners(gpa, cst, child, out);
        }
    }
}

fn collectAstScopes(
    gpa: Allocator,
    scope: *Ast.Scope,
    out: *std.ArrayList(*Ast.Scope),
) error{OutOfMemory}!void {
    for (scope.children.items) |c| {
        try out.append(gpa, c);
        try collectAstScopes(gpa, c, out);
    }
}

/// Populate `result.scope_for_cst_node` by pairing CST scope-openers
/// (fn_decl, compound_stmt, for_stmt) with non-root AST scopes in the same
/// DFS-open order. Both front-ends (Parser and CstLower) push scopes in
/// the exact order the CST nodes are opened, so index-zip yields a
/// correct mapping.
///
/// Idempotent: re-runs clear the existing map first. Called from
/// `parseFull` at the end of each full parse and from the hot path after
/// a successful splice.
pub fn buildScopeForCstNodeMap(
    arena: Allocator,
    result: *Incremental.ReparseResult,
) !void {
    result.scope_for_cst_node.clearRetainingCapacity();

    var cst_openers: std.ArrayList(Cst.NodeIndex) = .empty;
    defer cst_openers.deinit(arena);
    try collectCstOpeners(arena, &result.cst, result.cst.root(), &cst_openers);

    var ast_scopes: std.ArrayList(*Ast.Scope) = .empty;
    defer ast_scopes.deinit(arena);
    try collectAstScopes(arena, result.module.scope, &ast_scopes);

    // Parser/CstLower and the CST emit scope-openers in the same DFS-open
    // order, so cardinalities match. If they ever diverge, fall back to
    // an empty map — `scopeAtCstNode` still returns a valid scope (the
    // module) and the hot path's correctness degrades to a full
    // re-lower, not a crash.
    if (cst_openers.items.len != ast_scopes.items.len) return;

    try result.scope_for_cst_node.ensureTotalCapacity(arena, @intCast(cst_openers.items.len));
    for (cst_openers.items, ast_scopes.items) |opener, scope| {
        result.scope_for_cst_node.putAssumeCapacity(@intFromEnum(opener), scope);
    }
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "scopeAtCstNode: literal inside fn body resolves to block scope" {
    const src: [:0]const u8 = "fn f() { let x = 7; return x; }";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    // Locate the literal expression `7` — an anchor somewhere deep
    // inside the function body.
    const off: u32 = @intCast(std.mem.indexOfScalar(u8, src, '7').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = off,
        .end = off + 1,
        .new_text = "8",
    }) orelse return error.TestUnexpectedNull;

    const scope = scopeAtCstNode(&base, anchor.node);
    // The anchor's enclosing scope must be a block (the fn body), parent
    // must be a function scope, and grandparent must be the module.
    try testing.expectEqual(Ast.ScopeKind.block, scope.kind);
    const parent = scope.parent orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Ast.ScopeKind.function, parent.kind);
    const gp = parent.parent orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Ast.ScopeKind.module, gp.kind);
    try testing.expect(gp.parent == null);
}

test "scopeAtCstNode: module-level anchor falls through to module.scope" {
    const src: [:0]const u8 = "const x = 1;";
    var base = try Incremental.parseFull(testing.allocator, src);
    defer base.deinit();

    const off: u32 = @intCast(std.mem.indexOfScalar(u8, src, '1').?);
    const anchor = Incremental.findAnchor(&base.cst, .{
        .start = off,
        .end = off + 1,
        .new_text = "2",
    }) orelse return error.TestUnexpectedNull;

    const scope = scopeAtCstNode(&base, anchor.node);
    try testing.expectEqual(base.module.scope, scope);
}
