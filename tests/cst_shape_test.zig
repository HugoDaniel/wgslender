//! CST shape snapshots — asserts the tree's skeleton on hand-picked
//! sources, including the grammar-ambiguity cases the original plan
//! called out (template `<` vs comparison `<`, attribute-with-call,
//! nested compound statements, parse-error recovery).
//!
//! The snapshot is a compact S-expression that names every node kind
//! (tokens are elided). A spec reads as: "these sources, when parsed,
//! must produce these tree shapes." Small and targeted on purpose —
//! the full ~80-kind coverage matrix is out of scope; we focus on the
//! cases that regress silently.

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;
const Cst = wgslender.Cst;

fn renderNode(
    gpa: std.mem.Allocator,
    tree: *const Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    try buf.append(gpa, '(');
    try buf.appendSlice(gpa, @tagName(n.kind));
    const children = tree.children[n.first_child .. n.first_child + n.child_count];
    for (children) |el| {
        if (el.asNode()) |child| {
            try buf.append(gpa, ' ');
            try renderNode(gpa, tree, buf, child);
        }
    }
    try buf.append(gpa, ')');
}

fn expectShape(
    gpa: std.mem.Allocator,
    source: []const u8,
    expected: []const u8,
) !void {
    var result = try Incremental.parseFull(gpa, source);
    defer result.deinit();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try renderNode(gpa, &result.cst, &buf, result.cst.root());
    std.testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("source: {s}\nactual: {s}\n", .{ source, buf.items });
        return err;
    };
}

// =========================================================================
// Decls
// =========================================================================

test "cst shape: empty module" {
    try expectShape(std.testing.allocator, "", "(module)");
}

test "cst shape: single const decl" {
    try expectShape(
        std.testing.allocator,
        "const x = 1;",
        "(module (const_decl (literal_expr)))",
    );
}

test "cst shape: struct with trailing comma" {
    try expectShape(
        std.testing.allocator,
        "struct S { x: f32, }",
        "(module (struct_decl (type_ident)))",
    );
}

test "cst shape: empty struct" {
    try expectShape(
        std.testing.allocator,
        "struct S {}",
        "(module (struct_decl))",
    );
}

test "cst shape: alias" {
    try expectShape(
        std.testing.allocator,
        "alias T = vec3<f32>;",
        "(module (alias_decl (type_vec (template_args (type_ident)))))",
    );
}

// =========================================================================
// Grammar-ambiguity cases (the plan called these out explicitly)
// =========================================================================

test "cst shape: template args vs comparison — `array<f32, 2>`" {
    // The `<` and `>` here must be template delimiters, not comparisons.
    // If the parser mis-disambiguates we'd see `binary_expr` nodes.
    try expectShape(
        std.testing.allocator,
        "const a: array<f32, 2> = array(1, 2);",
        "(module (const_decl (type_array (template_args (type_ident) (literal_expr))) (call_expr (ident_expr) (literal_expr) (literal_expr))))",
    );
}

test "cst shape: attribute with call-expression argument" {
    try expectShape(
        std.testing.allocator,
        "@workgroup_size(compute_size()) fn main() {}",
        "(module (fn_decl (attribute_list (attribute (attribute_args (call_expr (ident_expr))))) (compound_stmt)))",
    );
}

test "cst shape: deeply nested compound statements" {
    // Three levels of braces: outer fn body, then two nested `{ ... }`.
    // The CST should show three `compound_stmt` nodes — the outermost is
    // always the fn body, then each explicit `{` opens another.
    try expectShape(
        std.testing.allocator,
        "fn f() { { { } } }",
        "(module (fn_decl (compound_stmt (compound_stmt (compound_stmt)))))",
    );
}

// =========================================================================
// Parse-error recovery
// =========================================================================

test "cst shape: malformed param list produces error_tree but sibling decls survive" {
    var result = try Incremental.parseFull(std.testing.allocator, "fn f( { } const y = 1;");
    defer result.deinit();
    // The module must still have two top-level children (the malformed
    // fn_decl and the following const_decl). Recovery shouldn't cascade
    // into a single flat error_tree swallowing everything.
    const root = result.cst.rootCursor();
    var decls_or_errors: usize = 0;
    for (root.childElements()) |el| {
        if (el.asNode()) |_| decls_or_errors += 1;
    }
    try std.testing.expect(decls_or_errors >= 2);
}

test "cst shape: phony assignment lowers to phony_stmt, not error_tree" {
    // The round-trip test alone cannot catch a regression here: a phony
    // statement swallowed into an `error_tree` still concatenates back to
    // the source byte-for-byte. Name the node explicitly.
    try expectShape(
        std.testing.allocator,
        "fn f() { _ = x; }",
        "(module (fn_decl (compound_stmt (phony_stmt (ident_expr)))))",
    );
}
