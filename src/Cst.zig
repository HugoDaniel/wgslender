//! Concrete syntax tree (green + red) for WGSL.
//!
//! The CST is a lossless, trivia-preserving view of the source. Every byte
//! of the original text is reachable either as a token (real or trivia) or
//! as an enclosing node's range. The AST is lowered from the CST in
//! `CstLower.zig`; consumers that don't care about layout stay on the AST.
//!
//! Build model (rust-analyzer style):
//!   - Parser emits an `Event` stream via `Builder.open` / `.close` /
//!     `.token` / `.err`.
//!   - `.openBefore(m)` lets a parser retroactively wrap an already-closed
//!     subtree under a new parent (needed for left-recursive binary
//!     expression precedence).
//!   - `Builder.finish(tokens, source)` linearizes the event stream into a
//!     flat green tree (`Tree`) in a single pass, resolving forward-parent
//!     chains on the fly.
//!
//! Green tree layout:
//!   - `nodes: MultiArrayList(Node)` — every interior node.
//!   - `children: []Element` — flat child table; each node's children are a
//!     contiguous range `[first_child, first_child + child_count)`. Each
//!     `Element` is either a node index or a token index, tagged by its
//!     high bit.

const std = @import("std");
const Lexer = @import("Lexer.zig");

// =========================================================================
// Kind — one variant per grammar production, plus trivia + recovery.
// =========================================================================

pub const Kind = enum(u16) {
    // Root
    module,

    // Directives
    directive,

    // Declarations (one per Ast.Decl variant)
    const_decl,
    override_decl,
    var_decl,
    let_decl,
    fn_decl,
    struct_decl,
    alias_decl,
    const_assert_decl,

    // Attributes
    attribute_list,
    attribute,
    attribute_args,

    // Types (one per Ast.Type variant)
    type_ident,
    type_vec,
    type_mat,
    type_array,
    type_ptr,
    type_atomic,
    type_sampler,
    type_texture,
    template_args,

    // Parameters & struct members
    parameter_list,
    parameter,
    struct_member_list,
    struct_member,

    // Statements (one per Ast.Stmt variant)
    compound_stmt,
    return_stmt,
    if_stmt,
    else_clause,
    switch_stmt,
    switch_body,
    switch_case,
    case_selector,
    for_stmt,
    while_stmt,
    loop_stmt,
    continuing_stmt,
    break_stmt,
    break_if_stmt,
    continue_stmt,
    discard_stmt,
    assign_stmt,
    incr_decr_stmt,
    call_stmt,
    decl_stmt,

    // Expressions (one per Ast.Expr variant)
    binary_expr,
    unary_expr,
    call_expr,
    index_expr,
    member_expr,
    paren_expr,
    ident_expr,
    literal_expr,

    // Helpers
    name,
    address_space_list,

    // Error recovery
    error_tree,

    /// Internal-only sentinel used by `Builder.finish` to mark events whose
    /// forward-parent chain has already been emitted. Never appears in a
    /// finalized `Tree` — leaking this into a tree is a bug.
    tombstone,

    pub fn isErrorRecovery(self: Kind) bool {
        return self == .error_tree;
    }
};

// =========================================================================
// Span — byte range, half-open.
// =========================================================================

pub const Span = struct {
    start: u32,
    end: u32,

    pub const empty: Span = .{ .start = 0, .end = 0 };

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    /// True if `self` fully contains `other`.
    pub fn contains(self: Span, other: Span) bool {
        return other.start >= self.start and other.end <= self.end;
    }

    /// True if both spans share at least one byte.
    pub fn overlaps(self: Span, other: Span) bool {
        return self.start < other.end and other.start < self.end;
    }
};

// =========================================================================
// Event stream
// =========================================================================

const Event = union(enum) {
    start: Start,
    finish,
    token: u32,
    @"error": []const u8,

    const Start = struct {
        kind: Kind,
        /// If non-null, index of another `.start` event in the same stream
        /// that this event's node should be reparented under at assembly
        /// time. Produced by `Builder.openBefore` to express precedence
        /// restructuring without rewriting the event list.
        forward_parent: ?u32 = null,
    };
};

// =========================================================================
// Builder
// =========================================================================

pub const Marker = enum(u32) {
    _,

    fn eventIndex(self: Marker) u32 {
        return @intFromEnum(self);
    }
};

pub const Builder = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event),
    open_count: u32,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{
            .gpa = gpa,
            .events = .empty,
            .open_count = 0,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.events.deinit(self.gpa);
    }

    /// Open a new node. The node's kind is not fixed yet — the parser
    /// discovers it during parsing and supplies it via `close` or
    /// `closeAs`. Until closed, the node is a placeholder.
    pub fn open(self: *Builder) !Marker {
        const idx: u32 = @intCast(self.events.items.len);
        try self.events.append(self.gpa, .{ .start = .{ .kind = .error_tree, .forward_parent = null } });
        self.open_count += 1;
        return @enumFromInt(idx);
    }

    /// Close the given marker's node with a final kind. Asserts the marker
    /// refers to an open node.
    pub fn close(self: *Builder, m: Marker, kind: Kind) !void {
        std.debug.assert(self.open_count > 0);
        std.debug.assert(kind != .tombstone);
        self.events.items[m.eventIndex()].start.kind = kind;
        try self.events.append(self.gpa, .finish);
        self.open_count -= 1;
    }

    /// Retroactively wrap an already-opened (and possibly already-closed)
    /// marker inside a new parent. Returns the new outer marker. The inner
    /// marker's event is reparented under the returned marker's event via
    /// a forward-parent link, which `finish` resolves at assembly time.
    ///
    /// Usage pattern for left-associative binary operators:
    ///     const m = p.open();
    ///     parseLeft();                // closes m
    ///     const wrap = p.openBefore(m);
    ///     parseOp();
    ///     parseRight();
    ///     p.close(wrap, .binary_expr);
    pub fn openBefore(self: *Builder, m: Marker) !Marker {
        const new_idx: u32 = @intCast(self.events.items.len);
        try self.events.append(self.gpa, .{ .start = .{ .kind = .error_tree, .forward_parent = null } });
        self.events.items[m.eventIndex()].start.forward_parent = new_idx;
        self.open_count += 1;
        return @enumFromInt(new_idx);
    }

    /// Discard a marker without producing a node. Abandoned markers leave
    /// no node in the tree; their tokens, if any were consumed, remain as
    /// children of the enclosing node. Useful for speculative parsing.
    pub fn abandon(self: *Builder, m: Marker) void {
        std.debug.assert(self.open_count > 0);
        self.events.items[m.eventIndex()].start.kind = .tombstone;
        self.open_count -= 1;
    }

    /// Attach the token at `token_index` (in the `TokenStream` passed to
    /// `finish`) as the next child of the currently-innermost open node.
    pub fn token(self: *Builder, token_index: u32) !void {
        try self.events.append(self.gpa, .{ .token = token_index });
    }

    /// Record a parser error at the current position. Attaches to the
    /// currently-innermost open node.
    pub fn err(self: *Builder, message: []const u8) !void {
        try self.events.append(self.gpa, .{ .@"error" = message });
    }

    /// Linearize the event stream into a `Tree`. All Tree-owned memory
    /// allocates in `arena` (which is expected to outlive the caller's
    /// access to the tree).
    pub fn finish(
        self: *Builder,
        arena: std.mem.Allocator,
        tokens: std.MultiArrayList(Lexer.Token),
        source: [:0]const u8,
    ) !Tree {
        std.debug.assert(self.open_count == 0);

        // Work buffers ------------------------------------------------------
        var nodes: std.MultiArrayList(Tree.Node) = .empty;
        errdefer nodes.deinit(arena);
        var children: std.ArrayListUnmanaged(Tree.Element) = .empty;
        errdefer children.deinit(arena);
        var errors: std.ArrayListUnmanaged(Tree.ErrorEntry) = .empty;
        errdefer errors.deinit(arena);

        // Open-stack entry: the node being built and the slice of its
        // children accumulated so far (we copy into `children` at close-time).
        const OpenNode = struct {
            node_idx: u32,
            pending_children: std.ArrayListUnmanaged(Tree.Element),
        };
        var stack: std.ArrayListUnmanaged(OpenNode) = .empty;
        defer stack.deinit(self.gpa);

        // Forward-parent chain scratch.
        var chain: std.ArrayListUnmanaged(Kind) = .empty;
        defer chain.deinit(self.gpa);

        // Source bounds for nodes that never saw a token — they collapse to
        // an empty span at the next token boundary.
        const tok_starts = tokens.items(.start);
        const tok_ends = tokens.items(.end);
        const tok_count: u32 = @intCast(tokens.len);
        var next_tok_idx: u32 = 0;

        const events = self.events.items;
        var ev_idx: u32 = 0;
        while (ev_idx < events.len) : (ev_idx += 1) {
            switch (events[ev_idx]) {
                .start => |start| {
                    if (start.kind == .tombstone) continue; // absorbed by a previous chain
                    // Walk forward-parent chain; outermost last.
                    chain.clearRetainingCapacity();
                    var chain_idx = ev_idx;
                    while (true) {
                        const e = &events[chain_idx].start;
                        try chain.append(self.gpa, e.kind);
                        const fp = e.forward_parent;
                        // Mark consumed (avoid re-processing on its own visit).
                        if (chain_idx != ev_idx) e.kind = .tombstone;
                        if (fp) |next| {
                            chain_idx = next;
                        } else break;
                    }

                    // Open outermost-first (reverse of traversal order).
                    var i = chain.items.len;
                    while (i > 0) {
                        i -= 1;
                        const kind = chain.items[i];

                        const node_idx: u32 = @intCast(nodes.len);
                        const span_start = if (next_tok_idx < tok_count) tok_starts[next_tok_idx] else @as(u32, @intCast(source.len));
                        try nodes.append(arena, .{
                            .kind = kind,
                            .start = span_start,
                            .end = span_start, // updated on close
                            .parent = @enumFromInt(if (stack.items.len == 0) 0 else stack.items[stack.items.len - 1].node_idx),
                            .first_child = 0,
                            .child_count = 0,
                        });

                        try stack.append(self.gpa, .{
                            .node_idx = node_idx,
                            .pending_children = .empty,
                        });

                        // Record the child in the parent, if any.
                        if (stack.items.len >= 2) {
                            const parent = &stack.items[stack.items.len - 2];
                            try parent.pending_children.append(self.gpa, Tree.Element.fromNode(node_idx));
                        }
                    }
                },
                .finish => {
                    std.debug.assert(stack.items.len > 0);
                    var top = stack.pop().?;
                    defer top.pending_children.deinit(self.gpa);

                    // Commit pending children into the flat children table.
                    const first_child: u32 = @intCast(children.items.len);
                    try children.appendSlice(arena, top.pending_children.items);
                    nodes.items(.first_child)[top.node_idx] = first_child;
                    nodes.items(.child_count)[top.node_idx] = @intCast(top.pending_children.items.len);

                    // Compute final span from consumed-tokens water mark.
                    const node_start = nodes.items(.start)[top.node_idx];
                    const end = if (next_tok_idx == 0)
                        node_start
                    else if (next_tok_idx <= tok_count)
                        tok_ends[next_tok_idx - 1]
                    else
                        @as(u32, @intCast(source.len));
                    // Never contract below start (handles empty nodes cleanly).
                    const final_end = if (end < node_start) node_start else end;
                    nodes.items(.end)[top.node_idx] = final_end;
                },
                .token => |tok_idx| {
                    std.debug.assert(stack.items.len > 0);
                    std.debug.assert(tok_idx < tok_count);
                    const top = &stack.items[stack.items.len - 1];
                    try top.pending_children.append(self.gpa, Tree.Element.fromToken(tok_idx));
                    next_tok_idx = @max(next_tok_idx, tok_idx + 1);
                    // If the enclosing node hasn't absorbed a real start byte
                    // yet (nothing consumed before it opened), back-fill.
                    const node_start = &nodes.items(.start)[top.node_idx];
                    if (node_start.* == 0 and tok_idx == 0) {
                        // No-op: start was correctly set to 0 already.
                    } else if (node_start.* > tok_starts[tok_idx]) {
                        node_start.* = tok_starts[tok_idx];
                    }
                },
                .@"error" => |msg| {
                    const current_node_idx = if (stack.items.len > 0)
                        @as(NodeIndex, @enumFromInt(stack.items[stack.items.len - 1].node_idx))
                    else
                        @as(NodeIndex, @enumFromInt(0));
                    try errors.append(arena, .{ .node = current_node_idx, .message = msg });
                },
            }
        }

        std.debug.assert(stack.items.len == 0);

        return .{
            .arena = arena,
            .source = source,
            .tokens = tokens,
            .nodes = nodes,
            .children = try children.toOwnedSlice(arena),
            .errors = try errors.toOwnedSlice(arena),
        };
    }
};

// =========================================================================
// Tree (green tree) + Cursor (red tree view)
// =========================================================================

pub const NodeIndex = enum(u32) {
    root = 0,
    _,

    pub fn raw(self: NodeIndex) u32 {
        return @intFromEnum(self);
    }
};

pub const Tree = struct {
    arena: std.mem.Allocator,
    source: [:0]const u8,
    tokens: std.MultiArrayList(Lexer.Token),
    nodes: std.MultiArrayList(Node),
    children: []Tree.Element,
    errors: []ErrorEntry,

    pub const Node = struct {
        kind: Kind,
        start: u32,
        end: u32,
        parent: NodeIndex,
        first_child: u32,
        child_count: u32,
    };

    /// A single child slot: either a sub-node or a token. Packed into u32
    /// to keep the children table compact; bit 31 distinguishes.
    pub const Element = packed struct(u32) {
        is_token: bool,
        index: u31,

        pub fn fromNode(node_idx: u32) Element {
            return .{ .is_token = false, .index = @intCast(node_idx) };
        }
        pub fn fromToken(tok_idx: u32) Element {
            return .{ .is_token = true, .index = @intCast(tok_idx) };
        }

        pub fn asNode(self: Element) ?NodeIndex {
            if (self.is_token) return null;
            return @enumFromInt(self.index);
        }

        pub fn asToken(self: Element) ?u32 {
            if (!self.is_token) return null;
            return self.index;
        }
    };

    pub const ErrorEntry = struct {
        node: NodeIndex,
        message: []const u8,
    };

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.arena);
        self.arena.free(self.children);
        self.arena.free(self.errors);
        self.tokens.deinit(self.arena);
    }

    pub fn root(self: *const Tree) NodeIndex {
        _ = self;
        return .root;
    }

    pub fn rootCursor(self: *const Tree) Cursor {
        return .{ .tree = self, .node = self.root() };
    }

    pub fn getNode(self: *const Tree, idx: NodeIndex) Node {
        const i = idx.raw();
        return .{
            .kind = self.nodes.items(.kind)[i],
            .start = self.nodes.items(.start)[i],
            .end = self.nodes.items(.end)[i],
            .parent = self.nodes.items(.parent)[i],
            .first_child = self.nodes.items(.first_child)[i],
            .child_count = self.nodes.items(.child_count)[i],
        };
    }

    pub fn childrenOf(self: *const Tree, idx: NodeIndex) []const Element {
        const n = self.getNode(idx);
        return self.children[n.first_child .. n.first_child + n.child_count];
    }

    pub fn nodeCount(self: *const Tree) u32 {
        return @intCast(self.nodes.len);
    }
};

// =========================================================================
// Cursor — red-tree navigation over a green tree.
// =========================================================================

pub const Cursor = struct {
    tree: *const Tree,
    node: NodeIndex,

    pub fn kind(c: Cursor) Kind {
        return c.tree.getNode(c.node).kind;
    }

    pub fn range(c: Cursor) Span {
        const n = c.tree.getNode(c.node);
        return .{ .start = n.start, .end = n.end };
    }

    pub fn text(c: Cursor) []const u8 {
        const r = c.range();
        return c.tree.source[r.start..r.end];
    }

    pub fn parent(c: Cursor) ?Cursor {
        if (c.node == .root) return null;
        const p = c.tree.getNode(c.node).parent;
        return .{ .tree = c.tree, .node = p };
    }

    /// Iterate this node's children (both sub-nodes and tokens).
    pub fn childElements(c: Cursor) []const Tree.Element {
        return c.tree.childrenOf(c.node);
    }

    /// First child that is a sub-node (tokens are skipped).
    pub fn firstChildNode(c: Cursor) ?Cursor {
        for (c.childElements()) |el| {
            if (el.asNode()) |n| return .{ .tree = c.tree, .node = n };
        }
        return null;
    }

    /// Next sibling of `c` under its parent. Returns `null` if `c` is the
    /// last child (or the root).
    pub fn nextSibling(c: Cursor) ?Cursor {
        const par = c.parent() orelse return null;
        const sibs = par.childElements();
        var i: usize = 0;
        while (i < sibs.len) : (i += 1) {
            if (sibs[i].asNode()) |n| if (n == c.node) {
                var j = i + 1;
                while (j < sibs.len) : (j += 1) {
                    if (sibs[j].asNode()) |nn| return .{ .tree = c.tree, .node = nn };
                }
                return null;
            };
        }
        return null;
    }

    /// Walk down to the smallest sub-node (including `c`) whose range fully
    /// contains `needle`. Returns `c` when no descendant is strictly
    /// smaller.
    pub fn findSmallestContaining(c: Cursor, needle: Span) Cursor {
        var cur = c;
        descend: while (true) {
            const sibs = cur.childElements();
            for (sibs) |el| {
                if (el.asNode()) |n| {
                    const child = Cursor{ .tree = cur.tree, .node = n };
                    if (child.range().contains(needle)) {
                        cur = child;
                        continue :descend;
                    }
                }
            }
            return cur;
        }
    }
};

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

fn makeTokenStream(arena: std.mem.Allocator, entries: []const Lexer.Token) !std.MultiArrayList(Lexer.Token) {
    var list: std.MultiArrayList(Lexer.Token) = .empty;
    try list.ensureTotalCapacity(arena, entries.len);
    for (entries) |t| list.appendAssumeCapacity(t);
    return list;
}

test "Cst.Builder: single leaf node with one token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .ident, .start = 0, .end = 3 },
        .{ .tag = .eof, .start = 3, .end = 3 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const m = try b.open();
    try b.token(0);
    try b.close(m, .ident_expr);

    var tree = try b.finish(arena.allocator(), tokens, "foo");
    defer tree.deinit();

    try testing.expectEqual(@as(u32, 1), tree.nodeCount());
    const root_cursor = tree.rootCursor();
    try testing.expectEqual(Kind.ident_expr, root_cursor.kind());
    try testing.expectEqualStrings("foo", root_cursor.text());
}

test "Cst.Builder: nested nodes produce correct spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Source: "let x = 1;"
    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .keyword_let, .start = 0, .end = 3 }, // let
        .{ .tag = .ident, .start = 4, .end = 5 }, // x
        .{ .tag = .eq, .start = 6, .end = 7 }, // =
        .{ .tag = .int_literal, .start = 8, .end = 9 }, // 1
        .{ .tag = .semicolon, .start = 9, .end = 10 }, // ;
        .{ .tag = .eof, .start = 10, .end = 10 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const decl = try b.open();
    try b.token(0); // let
    const name = try b.open();
    try b.token(1); // x
    try b.close(name, .name);
    try b.token(2); // =
    const rhs = try b.open();
    try b.token(3); // 1
    try b.close(rhs, .literal_expr);
    try b.token(4); // ;
    try b.close(decl, .let_decl);

    var tree = try b.finish(arena.allocator(), tokens, "let x = 1;");
    defer tree.deinit();

    const root_cursor = tree.rootCursor();
    try testing.expectEqual(Kind.let_decl, root_cursor.kind());
    try testing.expectEqual(@as(u32, 0), root_cursor.range().start);
    try testing.expectEqual(@as(u32, 10), root_cursor.range().end);
    try testing.expectEqualStrings("let x = 1;", root_cursor.text());

    // First child node (skipping tokens) should be the `name` wrapping `x`.
    const first = root_cursor.firstChildNode() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.name, first.kind());
    try testing.expectEqualStrings("x", first.text());

    // Next sibling should be the `literal_expr` wrapping `1`.
    const second = first.nextSibling() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.literal_expr, second.kind());
    try testing.expectEqualStrings("1", second.text());
    try testing.expectEqual(second.nextSibling(), null);
}

test "Cst.Builder.openBefore rewraps a closed subtree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Source: "a+b" — parser sees ident, then discovers + and wants to wrap
    // the ident as the left operand of a binary_expr.
    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .ident, .start = 0, .end = 1 }, // a
        .{ .tag = .plus, .start = 1, .end = 2 }, // +
        .{ .tag = .ident, .start = 2, .end = 3 }, // b
        .{ .tag = .eof, .start = 3, .end = 3 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const lhs = try b.open();
    try b.token(0);
    try b.close(lhs, .ident_expr);

    // Now wrap under a binary_expr.
    const wrap = try b.openBefore(lhs);
    try b.token(1); // +
    const rhs = try b.open();
    try b.token(2);
    try b.close(rhs, .ident_expr);
    try b.close(wrap, .binary_expr);

    var tree = try b.finish(arena.allocator(), tokens, "a+b");
    defer tree.deinit();

    const root_cursor = tree.rootCursor();
    try testing.expectEqual(Kind.binary_expr, root_cursor.kind());
    try testing.expectEqualStrings("a+b", root_cursor.text());

    // Children of the binary_expr: left ident_expr, + token, right ident_expr.
    const kids = root_cursor.childElements();
    try testing.expectEqual(@as(usize, 3), kids.len);
    try testing.expect(!kids[0].is_token);
    try testing.expect(kids[1].is_token);
    try testing.expect(!kids[2].is_token);
    const left = Cursor{ .tree = root_cursor.tree, .node = kids[0].asNode().? };
    const right = Cursor{ .tree = root_cursor.tree, .node = kids[2].asNode().? };
    try testing.expectEqual(Kind.ident_expr, left.kind());
    try testing.expectEqual(Kind.ident_expr, right.kind());
    try testing.expectEqualStrings("a", left.text());
    try testing.expectEqualStrings("b", right.text());
}

test "Cst.Builder: abandon leaves no node behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .ident, .start = 0, .end = 3 },
        .{ .tag = .eof, .start = 3, .end = 3 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const root = try b.open();
    const speculative = try b.open();
    b.abandon(speculative);
    try b.token(0);
    try b.close(root, .module);

    var tree = try b.finish(arena.allocator(), tokens, "foo");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 1), tree.nodeCount());
    try testing.expectEqual(Kind.module, tree.rootCursor().kind());
}

test "Cst.Builder: error messages are collected and attached to the open node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .eof, .start = 0, .end = 0 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const m = try b.open();
    try b.err("expected expression");
    try b.close(m, .error_tree);

    var tree = try b.finish(arena.allocator(), tokens, "");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.errors.len);
    try testing.expectEqualStrings("expected expression", tree.errors[0].message);
    try testing.expectEqual(tree.errors[0].node, tree.root());
}

test "Cst.Cursor.findSmallestContaining drills to the tightest node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Source: "fn f() { return 1; }" — token ranges are approximate, we only
    // rely on the ordering and cover.
    const tokens = try makeTokenStream(arena.allocator(), &.{
        .{ .tag = .keyword_fn, .start = 0, .end = 2 },
        .{ .tag = .ident, .start = 3, .end = 4 },
        .{ .tag = .l_paren, .start = 4, .end = 5 },
        .{ .tag = .r_paren, .start = 5, .end = 6 },
        .{ .tag = .l_brace, .start = 7, .end = 8 },
        .{ .tag = .keyword_return, .start = 9, .end = 15 },
        .{ .tag = .int_literal, .start = 16, .end = 17 },
        .{ .tag = .semicolon, .start = 17, .end = 18 },
        .{ .tag = .r_brace, .start = 19, .end = 20 },
        .{ .tag = .eof, .start = 20, .end = 20 },
    });

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const module = try b.open();
    const fn_decl = try b.open();
    try b.token(0); // fn
    try b.token(1); // f
    try b.token(2); // (
    try b.token(3); // )
    const body = try b.open();
    try b.token(4); // {
    const ret = try b.open();
    try b.token(5); // return
    const lit = try b.open();
    try b.token(6); // 1
    try b.close(lit, .literal_expr);
    try b.token(7); // ;
    try b.close(ret, .return_stmt);
    try b.token(8); // }
    try b.close(body, .compound_stmt);
    try b.close(fn_decl, .fn_decl);
    try b.close(module, .module);

    var tree = try b.finish(arena.allocator(), tokens, "fn f() { return 1; }");
    defer tree.deinit();

    // Looking for span "1" at offset 16..17 should land on `literal_expr`.
    const target: Span = .{ .start = 16, .end = 17 };
    const hit = tree.rootCursor().findSmallestContaining(target);
    try testing.expectEqual(Kind.literal_expr, hit.kind());
    try testing.expectEqualStrings("1", hit.text());

    // A wider span (16..18) covers both the literal and the `;`, so the
    // tightest wrap is the return_stmt.
    const hit2 = tree.rootCursor().findSmallestContaining(.{ .start = 16, .end = 18 });
    try testing.expectEqual(Kind.return_stmt, hit2.kind());
}

test "Cst.Tree.Element packed layout is 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Tree.Element));
}
