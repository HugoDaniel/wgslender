//! Lower a `Cst.Tree` into an `Ast.Module`.
//!
//! Stage 4 (minimum-viable) entry point. Walks the green tree once to build
//! AST nodes, register symbols, and construct the scope tree (Pass 1),
//! then runs the shared `AstVisit.visit` (Pass 2) to bind identifiers and
//! mark purity. The produced `Ast.Module` is structurally equivalent to
//! what `Parser.parse` would yield for the same source — that equivalence
//! is enforced by `tests/cst_lower_test.zig`.
//!
//! Error recovery: CST `error_tree` subtrees are skipped. A clean-parse
//! source is assumed; malformed input coverage stays in `fuzz_test.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const AstVisit = @import("AstVisit.zig");
const Cst = @import("Cst.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

const Tag = Lexer.Tag;

pub fn lowerTree(
    gpa: Allocator,
    arena: Allocator,
    cst: *const Cst.Tree,
) !*Ast.Module {
    return lowerTreeWithErrors(gpa, arena, cst, null);
}

/// Same as `lowerTree`, but lets the caller observe the visit-pass error
/// list. When `errors_out` is non-null, the caller owns the storage and
/// the lower's `LowerCtx.errors` aliases it — entries appended during
/// Pass 2 (identifier resolution) survive past this call. When null,
/// errors land in a throwaway local that goes out of scope (the
/// arena-owned message bytes leak harmlessly into the arena, matching
/// historical behavior).
pub fn lowerTreeWithErrors(
    gpa: Allocator,
    arena: Allocator,
    cst: *const Cst.Tree,
    errors_out: ?*std.ArrayListUnmanaged(Parser.ParseError),
) !*Ast.Module {
    _ = gpa;

    const module_scope = try arena.create(Ast.Scope);
    module_scope.* = Ast.Scope.init(null, .module);

    const module = try arena.create(Ast.Module);
    module.* = Ast.Module.init(module_scope, cst.source);

    var local_errors: std.ArrayListUnmanaged(Parser.ParseError) = .empty;
    const errors_ptr = errors_out orelse &local_errors;

    var ctx = LowerCtx{
        .arena = arena,
        .cst = cst,
        .token_tags = cst.tokens.items(.tag),
        .token_starts = cst.tokens.items(.start),
        .token_ends = cst.tokens.items(.end),
        .symbols = .empty,
        .scope = module_scope,
        .scopes_in_order = .empty,
        .errors = errors_ptr.*,
    };

    const root = cst.rootCursor();
    for (root.childElements()) |el| {
        const node_idx = el.asNode() orelse continue;
        const kind = cst.getNode(node_idx).kind;
        const cur = Cst.Cursor{ .tree = cst, .node = node_idx };
        switch (kind) {
            .directive => {
                const dir = try ctx.lowerDirective(cur);
                try module.directives.append(arena, dir);
            },
            .const_decl,
            .override_decl,
            .var_decl,
            .let_decl,
            .fn_decl,
            .struct_decl,
            .alias_decl,
            .const_assert_decl,
            => {
                if (try ctx.lowerDecl(cur, kind)) |decl| {
                    try module.declarations.append(arena, decl);
                }
            },
            .error_tree => {},
            else => {},
        }
    }

    module.symbols = ctx.symbols;

    var visit_ctx = AstVisit.Context{
        .arena = arena,
        .symbols = module.symbols.items,
        .scopes_in_order = ctx.scopes_in_order.items,
        .scope = module_scope,
        .errors = &ctx.errors,
        .safety_budget = @as(usize, @max(64, cst.tokens.len * 2)),
    };
    try AstVisit.visit(&visit_ctx, module);

    // Publish accumulated errors (Pass 1 redeclarations + Pass 2 visit
    // diagnostics) back to the caller's storage. Both bodies share the
    // arena, so the message bytes survive past this call regardless.
    errors_ptr.* = ctx.errors;

    return module;
}

// =========================================================================
// Subtree lowering (for `Incremental.reparse`'s hot path)
// =========================================================================

/// Discriminated result of `lowerSubtree`. Callers dispatch on this to
/// splice the right slot in the prev `Ast.Module`.
pub const LoweredSubtree = union(enum) {
    stmt: Ast.Stmt,
    expr: Ast.Expr,
};

/// Lower a single anchor-kind subtree into its AST form. Intended for
/// the symbol-free incremental hot path: the subtree kinds that
/// `Incremental` classifies as `.symbol_free` (expression anchors and
/// non-scope-introducing statement anchors). The lowered output has
/// ident references left as `.none` — a subsequent targeted re-visit
/// resolves them against the prev module's symbol table.
///
/// Allocates from `arena` (the prev module's arena on the hot path so
/// nodes are reachable from `Module`). Uses an empty throwaway symbol
/// table / scope because no new symbols are introduced by
/// symbol-free anchors; if a symbol IS introduced (e.g. decl_stmt), the
/// caller must classify as non-symbol-free and fall back.
pub fn lowerSubtree(
    arena: Allocator,
    cst: *const Cst.Tree,
    node: Cst.NodeIndex,
) error{ OutOfMemory, InvalidCst }!LoweredSubtree {
    const throwaway_scope = try arena.create(Ast.Scope);
    throwaway_scope.* = Ast.Scope.init(null, .block);

    var ctx = LowerCtx{
        .arena = arena,
        .cst = cst,
        .token_tags = cst.tokens.items(.tag),
        .token_starts = cst.tokens.items(.start),
        .token_ends = cst.tokens.items(.end),
        .symbols = .empty,
        .scope = throwaway_scope,
        .scopes_in_order = .empty,
        .errors = .empty,
    };

    const kind = ctx.nodeKind(node);
    switch (kind) {
        // Expression anchors.
        .literal_expr,
        .ident_expr,
        .binary_expr,
        .unary_expr,
        .call_expr,
        .index_expr,
        .member_expr,
        .paren_expr,
        => return .{ .expr = try ctx.lowerExpr(node) },

        // Statement anchors (non-scope-introducing). `compound_stmt`
        // and control-flow statements deliberately fall through to
        // InvalidCst so callers classify them as non-symbol-free.
        .return_stmt,
        .assign_stmt,
        .incr_decr_stmt,
        .call_stmt,
        .break_stmt,
        .break_if_stmt,
        .continue_stmt,
        .discard_stmt,
        => {
            const stmt = (try ctx.lowerStmt(node)) orelse return error.InvalidCst;
            return .{ .stmt = stmt };
        },

        else => return error.InvalidCst,
    }
}

/// Output of `lowerSubtreeInScope`: the lowered stmt plus every scope
/// the lowering pushed (in DFS creation order), so the incremental hot
/// path can feed them to a subsequent `AstVisit` as `scopes_in_order`.
pub const SubtreeInScopeOut = struct {
    stmt: Ast.Stmt,
    new_scopes: std.ArrayListUnmanaged(*Ast.Scope),
};

/// Lower a `compound_stmt` or `decl_stmt` subtree that DOES introduce
/// new scopes and/or symbols. Used by the Phase 2 in-place hot path:
/// declared symbols are appended to `symbols` at fresh indices (old
/// `SymbolIndex` values stay valid), and new scopes are pushed under
/// `parent_scope` in creation order.
///
/// Callers must position `parent_scope` at the AST scope that will own
/// the new subtree's top-level decls (function body's block scope for
/// a top-level compound, enclosing compound's block scope for a nested
/// compound or decl_stmt).
///
/// Does NOT run Pass 2 — ident refs are left unresolved. The caller
/// runs `AstVisit.visitSubtreeStmt` in `.add` mode with the returned
/// `new_scopes` as `scopes_in_order`.
pub fn lowerSubtreeInScope(
    arena: Allocator,
    cst: *const Cst.Tree,
    node: Cst.NodeIndex,
    parent_scope: *Ast.Scope,
    symbols: *std.ArrayListUnmanaged(Ast.Symbol),
) error{ OutOfMemory, InvalidCst }!SubtreeInScopeOut {
    var ctx = LowerCtx{
        .arena = arena,
        .cst = cst,
        .token_tags = cst.tokens.items(.tag),
        .token_starts = cst.tokens.items(.start),
        .token_ends = cst.tokens.items(.end),
        .symbols = symbols.*,
        .scope = parent_scope,
        .scopes_in_order = .empty,
        .errors = .empty,
    };

    const kind = ctx.nodeKind(node);
    const stmt: Ast.Stmt = switch (kind) {
        .compound_stmt => .{ .compound = try ctx.lowerCompoundStmt(ctx.nodeCursor(node)) },
        .decl_stmt => (try ctx.lowerDeclStmt(ctx.nodeCursor(node))) orelse return error.InvalidCst,
        else => return error.InvalidCst,
    };

    // Hand the (possibly-grown) symbol list back to the caller so they
    // own future growth on the same arena-backed storage.
    symbols.* = ctx.symbols;

    return .{ .stmt = stmt, .new_scopes = ctx.scopes_in_order };
}

// =========================================================================
// LowerCtx — shared state for the walk.
// =========================================================================

const LowerCtx = struct {
    arena: Allocator,
    cst: *const Cst.Tree,
    token_tags: []const Tag,
    token_starts: []const u32,
    token_ends: []const u32,
    symbols: std.ArrayListUnmanaged(Ast.Symbol),
    scope: *Ast.Scope,
    scopes_in_order: std.ArrayListUnmanaged(*Ast.Scope),
    errors: std.ArrayListUnmanaged(Parser.ParseError),

    // ---- symbol / scope helpers (mirror Parser.declareSymbol etc.) ------

    fn declareSymbol(
        self: *LowerCtx,
        name: []const u8,
        kind: Ast.Symbol.Kind,
        flags: Ast.Symbol.Flags,
        loc: u32,
    ) !Ast.SymbolIndex {
        if (self.scope.members.get(name) != null) {
            const msg = std.fmt.allocPrint(self.arena, "redeclaration of '{s}'", .{name}) catch "redeclaration of identifier";
            self.errors.append(self.arena, .{ .message = msg, .pos = loc, .code = "E0101" }) catch {};
        }
        std.debug.assert(self.symbols.items.len < std.math.maxInt(u32));
        const idx: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.arena, .{
            .original_name = name,
            .kind = kind,
            .flags = flags,
            .use_count = 0,
            .loc = loc,
        });
        try self.scope.members.put(self.arena, name, .{
            .ref = @enumFromInt(idx),
            .loc = loc,
        });
        return @enumFromInt(idx);
    }

    fn declareSymbolNoScope(
        self: *LowerCtx,
        name: []const u8,
        kind: Ast.Symbol.Kind,
        flags: Ast.Symbol.Flags,
        loc: u32,
    ) !Ast.SymbolIndex {
        std.debug.assert(self.symbols.items.len < std.math.maxInt(u32));
        const idx: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.arena, .{
            .original_name = name,
            .kind = kind,
            .flags = flags,
            .use_count = 0,
            .loc = loc,
        });
        return @enumFromInt(idx);
    }

    fn pushScope(self: *LowerCtx, kind: Ast.ScopeKind) !void {
        const new_scope = try self.arena.create(Ast.Scope);
        new_scope.* = Ast.Scope.init(self.scope, kind);
        var sib: u32 = 0;
        for (self.scope.children.items) |c| {
            if (c.kind == kind) sib += 1;
        }
        new_scope.sibling_index = sib;
        try self.scope.children.append(self.arena, new_scope);
        self.scope = new_scope;
        try self.scopes_in_order.append(self.arena, new_scope);
    }

    fn popScope(self: *LowerCtx) void {
        std.debug.assert(self.scope.parent != null);
        if (self.scope.parent) |p| self.scope = p;
    }

    // ---- token / child access --------------------------------------------

    fn tokenTag(self: *const LowerCtx, token: u32) Tag {
        return self.token_tags[token];
    }

    fn tokenText(self: *const LowerCtx, token: u32) []const u8 {
        return self.cst.source[self.token_starts[token]..self.token_ends[token]];
    }

    fn tokenStart(self: *const LowerCtx, token: u32) u32 {
        return self.token_starts[token];
    }

    fn tokenEnd(self: *const LowerCtx, token: u32) u32 {
        return self.token_ends[token];
    }

    fn nodeKind(self: *const LowerCtx, n: Cst.NodeIndex) Cst.Kind {
        return self.cst.getNode(n).kind;
    }

    fn nodeCursor(self: *const LowerCtx, n: Cst.NodeIndex) Cst.Cursor {
        return .{ .tree = self.cst, .node = n };
    }

    fn nodeSpan(self: *const LowerCtx, n: Cst.NodeIndex) Ast.Span {
        const node = self.cst.getNode(n);
        return .{ .start = node.start, .end = node.end };
    }

    /// Byte span of the first-through-last *non-trivia* tokens beneath this
    /// node. Parser sets `Ast.Span` from `currentStart()` / `prevTokenEnd()`
    /// which are non-trivia-based, so leading/trailing comments or
    /// whitespace are excluded. A raw CST node span includes that trivia,
    /// so equivalence requires stripping it here.
    fn nonTriviaSpan(self: *const LowerCtx, n: Cst.NodeIndex) Ast.Span {
        var state: NonTriviaState = .{};
        self.walkNonTrivia(n, &state);
        if (state.first_start == null or state.last_end == null) {
            return self.nodeSpan(n);
        }
        return .{ .start = state.first_start.?, .end = state.last_end.? };
    }

    const NonTriviaState = struct {
        first_start: ?u32 = null,
        last_end: ?u32 = null,
    };

    fn walkNonTrivia(self: *const LowerCtx, n: Cst.NodeIndex, state: *NonTriviaState) void {
        const node = self.cst.getNode(n);
        const children = self.cst.children[node.first_child .. node.first_child + node.child_count];
        for (children) |el| {
            if (el.asToken()) |token| {
                if (self.token_tags[token].isTrivia()) continue;
                const s = self.token_starts[token];
                const e = self.token_ends[token];
                if (state.first_start == null) state.first_start = s;
                state.last_end = e;
            } else if (el.asNode()) |child| {
                self.walkNonTrivia(child, state);
            }
        }
    }

    // =====================================================================
    // Walker — iterate a node's children, skipping trivia tokens.
    // =====================================================================

    const Walker = struct {
        ctx: *LowerCtx,
        children: []const Cst.Tree.Element,
        i: usize = 0,

        fn skipTrivia(self: *Walker) void {
            while (self.i < self.children.len) : (self.i += 1) {
                const el = self.children[self.i];
                if (el.asToken()) |token| {
                    if (self.ctx.tokenTag(token).isTrivia()) continue;
                }
                return;
            }
        }

        fn peekElement(self: *Walker) ?Cst.Tree.Element {
            self.skipTrivia();
            if (self.i >= self.children.len) return null;
            return self.children[self.i];
        }

        fn peekTokenTag(self: *Walker) ?Tag {
            const el = self.peekElement() orelse return null;
            const token = el.asToken() orelse return null;
            return self.ctx.tokenTag(token);
        }

        fn peekNodeKind(self: *Walker) ?Cst.Kind {
            const el = self.peekElement() orelse return null;
            const node = el.asNode() orelse return null;
            return self.ctx.nodeKind(node);
        }

        fn eatToken(self: *Walker, tag: Tag) ?u32 {
            const el = self.peekElement() orelse return null;
            const token = el.asToken() orelse return null;
            if (self.ctx.tokenTag(token) != tag) return null;
            self.i += 1;
            return token;
        }

        fn eatAnyToken(self: *Walker) ?u32 {
            const el = self.peekElement() orelse return null;
            const token = el.asToken() orelse return null;
            self.i += 1;
            return token;
        }

        fn eatAnyNode(self: *Walker) ?Cst.NodeIndex {
            const el = self.peekElement() orelse return null;
            const node = el.asNode() orelse return null;
            self.i += 1;
            return node;
        }

        fn eatNodeKind(self: *Walker, want: Cst.Kind) ?Cst.NodeIndex {
            const el = self.peekElement() orelse return null;
            const node = el.asNode() orelse return null;
            if (self.ctx.nodeKind(node) != want) return null;
            self.i += 1;
            return node;
        }
    };

    fn walker(self: *LowerCtx, cur: Cst.Cursor) Walker {
        return .{ .ctx = self, .children = cur.childElements() };
    }

    // =====================================================================
    // Directives
    // =====================================================================

    fn lowerDirective(self: *LowerCtx, cur: Cst.Cursor) !Ast.Directive {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);

        const kw = w.eatAnyToken() orelse return error.InvalidCst;
        switch (self.tokenTag(kw)) {
            .keyword_enable => {
                var features: std.ArrayListUnmanaged([]const u8) = .empty;
                while (true) {
                    const t = w.peekTokenTag() orelse break;
                    if (t == .ident) {
                        const token = w.eatAnyToken().?;
                        try features.append(self.arena, self.tokenText(token));
                    } else if (t == .comma) {
                        _ = w.eatAnyToken();
                    } else break;
                }
                return .{ .enable = .{ .features = features, .span = span } };
            },
            .keyword_requires => {
                var features: std.ArrayListUnmanaged([]const u8) = .empty;
                while (true) {
                    const t = w.peekTokenTag() orelse break;
                    if (t == .ident) {
                        const token = w.eatAnyToken().?;
                        try features.append(self.arena, self.tokenText(token));
                    } else if (t == .comma) {
                        _ = w.eatAnyToken();
                    } else break;
                }
                return .{ .requires = .{ .features = features, .span = span } };
            },
            .keyword_diagnostic => {
                _ = w.eatToken(.l_paren);
                var severity: []const u8 = "";
                var rule: []const u8 = "";
                if (w.eatToken(.ident)) |token| severity = self.tokenText(token);
                _ = w.eatToken(.comma);
                if (w.eatToken(.ident)) |token| rule = self.tokenText(token);
                _ = w.eatToken(.r_paren);
                return .{ .diagnostic = .{ .severity = severity, .rule = rule, .span = span } };
            },
            else => return error.InvalidCst,
        }
    }

    // =====================================================================
    // Declarations (module + local via decl_stmt)
    // =====================================================================

    fn lowerDecl(self: *LowerCtx, cur: Cst.Cursor, kind: Cst.Kind) !?Ast.Decl {
        return switch (kind) {
            .const_decl => .{ .@"const" = try self.lowerConstDecl(cur) },
            .override_decl => .{ .override = try self.lowerOverrideDecl(cur) },
            .var_decl => .{ .@"var" = try self.lowerVarDecl(cur) },
            .let_decl => .{ .let = try self.lowerLetDecl(cur) },
            .fn_decl => .{ .function = try self.lowerFunctionDecl(cur) },
            .struct_decl => .{ .@"struct" = try self.lowerStructDecl(cur) },
            .alias_decl => .{ .alias = try self.lowerAliasDecl(cur) },
            .const_assert_decl => .{ .const_assert = try self.lowerConstAssertDecl(cur) },
            else => null,
        };
    }

    fn lowerConstDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.ConstDecl {
        const decl = try self.arena.create(Ast.ConstDecl);
        decl.* = .{ .name = .none, .decl_span = self.nonTriviaSpan(cur.node) };

        var w = self.walker(cur);
        // Skip any attribute_list (const doesn't carry attrs on the Ast node).
        _ = w.eatNodeKind(.attribute_list);
        _ = w.eatToken(.keyword_const);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .@"const", .{}, self.tokenStart(token));
        }
        if (w.eatToken(.colon) != null) {
            if (w.eatAnyNode()) |n| decl.typ = try self.lowerType(n);
        }
        _ = w.eatToken(.eq);
        if (w.eatAnyNode()) |n| decl.initializer = try self.lowerExpr(n);
        return decl;
    }

    fn lowerOverrideDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.OverrideDecl {
        const decl = try self.arena.create(Ast.OverrideDecl);
        decl.* = .{ .attributes = .empty, .name = .none, .decl_span = self.nonTriviaSpan(cur.node) };

        var w = self.walker(cur);
        if (w.eatNodeKind(.attribute_list)) |n| decl.attributes = try self.lowerAttributeList(self.nodeCursor(n));
        _ = w.eatToken(.keyword_override);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .override, .{}, self.tokenStart(token));
        }
        if (w.eatToken(.colon) != null) {
            if (w.eatAnyNode()) |n| decl.typ = try self.lowerType(n);
        }
        if (w.eatToken(.eq) != null) {
            if (w.eatAnyNode()) |n| decl.initializer = try self.lowerExpr(n);
        }
        return decl;
    }

    fn lowerVarDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.VarDecl {
        const decl = try self.arena.create(Ast.VarDecl);
        decl.* = .{
            .attributes = .empty,
            .address_space = .none,
            .access_mode = .none,
            .name = .none,
            .decl_span = self.nonTriviaSpan(cur.node),
        };

        var w = self.walker(cur);
        if (w.eatNodeKind(.attribute_list)) |n| decl.attributes = try self.lowerAttributeList(self.nodeCursor(n));
        _ = w.eatToken(.keyword_var);
        if (w.eatToken(.lt) != null) {
            if (w.eatToken(.ident)) |token| decl.address_space = addressSpaceFromText(self.tokenText(token));
            if (w.eatToken(.comma) != null) {
                if (w.eatToken(.ident)) |token| decl.access_mode = accessModeFromText(self.tokenText(token));
            }
            _ = w.eatToken(.gt);
        }

        var flags: Ast.Symbol.Flags = .{};
        if (decl.address_space == .uniform or decl.address_space == .storage) {
            flags.is_external_binding = true;
        }

        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .@"var", flags, self.tokenStart(token));
        }
        if (w.eatToken(.colon) != null) {
            if (w.eatAnyNode()) |n| decl.typ = try self.lowerType(n);
        }
        if (w.eatToken(.eq) != null) {
            if (w.eatAnyNode()) |n| decl.initializer = try self.lowerExpr(n);
        }
        return decl;
    }

    fn lowerLetDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.LetDecl {
        const decl = try self.arena.create(Ast.LetDecl);
        decl.* = .{ .name = .none, .decl_span = self.nonTriviaSpan(cur.node) };

        var w = self.walker(cur);
        _ = w.eatNodeKind(.attribute_list);
        _ = w.eatToken(.keyword_let);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .let, .{}, self.tokenStart(token));
        }
        if (w.eatToken(.colon) != null) {
            if (w.eatAnyNode()) |n| decl.typ = try self.lowerType(n);
        }
        _ = w.eatToken(.eq);
        if (w.eatAnyNode()) |n| decl.initializer = try self.lowerExpr(n);
        return decl;
    }

    fn lowerFunctionDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.FunctionDecl {
        const decl = try self.arena.create(Ast.FunctionDecl);
        decl.* = .{
            .attributes = .empty,
            .name = .none,
            .parameters = .empty,
            .return_attr = .empty,
            .decl_span = self.nonTriviaSpan(cur.node),
        };

        var w = self.walker(cur);
        if (w.eatNodeKind(.attribute_list)) |n| decl.attributes = try self.lowerAttributeList(self.nodeCursor(n));

        const is_entry_point = blk: {
            const entry_names = std.StaticStringMap(void).initComptime(.{
                .{ "vertex", {} },
                .{ "fragment", {} },
                .{ "compute", {} },
            });
            for (decl.attributes.items) |attr| {
                if (entry_names.has(attr.name)) break :blk true;
            }
            break :blk false;
        };
        var flags: Ast.Symbol.Flags = .{};
        if (is_entry_point) {
            flags.is_entry_point = true;
            flags.must_not_be_renamed = true;
        }

        _ = w.eatToken(.keyword_fn);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .function, flags, self.tokenStart(token));
        }

        try self.pushScope(.function);

        // Parameters: loose tokens + attribute_list + type_* nodes between
        // `(` and `)`. Parser's parseParameters walks them linearly; mirror
        // that here.
        _ = w.eatToken(.l_paren);
        decl.parameters = try self.lowerParametersInline(&w);
        _ = w.eatToken(.r_paren);

        // Optional `-> [@attrs] return_type`.
        if (w.eatToken(.arrow) != null) {
            if (w.peekNodeKind()) |k| {
                if (k == .attribute_list) {
                    const n = w.eatAnyNode().?;
                    decl.return_attr = try self.lowerAttributeList(self.nodeCursor(n));
                }
            }
            if (w.eatAnyNode()) |n| decl.return_type = try self.lowerType(n);
        }

        if (w.eatNodeKind(.compound_stmt)) |n| decl.body = try self.lowerCompoundStmt(self.nodeCursor(n));

        self.popScope();
        return decl;
    }

    /// Walks parameters between `(` and `)` — which live as loose children
    /// of the `fn_decl` node (Parser does not wrap them in a
    /// `parameter_list` marker today).
    fn lowerParametersInline(self: *LowerCtx, w: *Walker) !std.ArrayListUnmanaged(Ast.Parameter) {
        var params: std.ArrayListUnmanaged(Ast.Parameter) = .empty;
        while (true) {
            if (w.peekTokenTag()) |t| {
                if (t == .r_paren) break;
                if (t == .comma) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            var param_attrs: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
            var param_start: ?u32 = null;
            if (w.peekNodeKind()) |k| {
                if (k == .attribute_list) {
                    const an = w.eatAnyNode().?;
                    param_start = self.nonTriviaSpan(an).start;
                    param_attrs = try self.lowerAttributeList(self.nodeCursor(an));
                }
            }
            const name_tok = w.eatToken(.ident) orelse w.eatToken(.reserved_ident) orelse break;
            const text = self.tokenText(name_tok);
            const loc = self.tokenStart(name_tok);
            if (param_start == null) param_start = loc;
            const name = try self.declareSymbol(text, .parameter, .{}, loc);
            _ = w.eatToken(.colon);
            var typ: Ast.Type = undefined;
            if (w.eatAnyNode()) |tn| {
                typ = try self.lowerType(tn);
            } else {
                // Missing type on recovery path — build a placeholder ident.
                const ident = try self.arena.create(Ast.IdentType);
                ident.* = .{ .name = "", .ref = .none, .loc = loc, .span = .empty };
                typ = .{ .ident = ident };
            }
            const type_end = typ.span().end;
            const param_end = if (type_end != 0) type_end else self.tokenEnd(name_tok);
            try params.append(self.arena, .{
                .attributes = param_attrs,
                .name = name,
                .typ = typ,
                .span = .{ .start = param_start.?, .end = param_end },
            });
        }
        return params;
    }

    fn lowerStructDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.StructDecl {
        const decl = try self.arena.create(Ast.StructDecl);
        decl.* = .{ .name = .none, .members = .empty, .decl_span = self.nonTriviaSpan(cur.node) };

        var w = self.walker(cur);
        _ = w.eatNodeKind(.attribute_list);
        _ = w.eatToken(.keyword_struct);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            decl.name = try self.declareSymbol(self.tokenText(token), .@"struct", .{}, self.tokenStart(token));
        }
        _ = w.eatToken(.l_brace);

        while (true) {
            if (w.peekTokenTag()) |t| {
                if (t == .r_brace or t == .eof) break;
                if (t == .comma) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            var member_attrs: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
            var member_start: ?u32 = null;
            if (w.peekNodeKind()) |k| {
                if (k == .attribute_list) {
                    const an = w.eatAnyNode().?;
                    member_start = self.nonTriviaSpan(an).start;
                    member_attrs = try self.lowerAttributeList(self.nodeCursor(an));
                }
            }
            const name_tok = w.eatToken(.ident) orelse w.eatToken(.reserved_ident) orelse break;
            const text = self.tokenText(name_tok);
            const loc = self.tokenStart(name_tok);
            if (member_start == null) member_start = loc;
            const name = try self.declareSymbolNoScope(text, .member, .{}, loc);
            _ = w.eatToken(.colon);
            var typ: Ast.Type = undefined;
            if (w.eatAnyNode()) |tn| {
                typ = try self.lowerType(tn);
            } else {
                const ident = try self.arena.create(Ast.IdentType);
                ident.* = .{ .name = "", .ref = .none, .loc = loc, .span = .empty };
                typ = .{ .ident = ident };
            }
            const type_end = typ.span().end;
            const member_end = if (type_end != 0) type_end else self.tokenEnd(name_tok);
            try decl.members.append(self.arena, .{
                .attributes = member_attrs,
                .name = name,
                .typ = typ,
                .span = .{ .start = member_start.?, .end = member_end },
            });
        }
        _ = w.eatToken(.r_brace);
        return decl;
    }

    fn lowerAliasDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.AliasDecl {
        const decl = try self.arena.create(Ast.AliasDecl);

        var w = self.walker(cur);
        _ = w.eatNodeKind(.attribute_list);
        _ = w.eatToken(.keyword_alias);
        var name: Ast.SymbolIndex = .none;
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            name = try self.declareSymbol(self.tokenText(token), .alias, .{}, self.tokenStart(token));
        }
        _ = w.eatToken(.eq);
        var typ: Ast.Type = undefined;
        if (w.eatAnyNode()) |n| {
            typ = try self.lowerType(n);
        } else {
            const ident = try self.arena.create(Ast.IdentType);
            ident.* = .{ .name = "", .ref = .none, .loc = 0, .span = .empty };
            typ = .{ .ident = ident };
        }
        decl.* = .{ .name = name, .typ = typ, .decl_span = self.nonTriviaSpan(cur.node) };
        return decl;
    }

    fn lowerConstAssertDecl(self: *LowerCtx, cur: Cst.Cursor) !*Ast.ConstAssertDecl {
        const decl = try self.arena.create(Ast.ConstAssertDecl);

        var w = self.walker(cur);
        _ = w.eatNodeKind(.attribute_list);
        // `const` `const_assert` OR `const_assert` alone.
        _ = w.eatToken(.keyword_const);
        _ = w.eatToken(.keyword_const_assert);
        if (w.eatAnyNode()) |n| {
            decl.* = .{ .expr = try self.lowerExpr(n) };
        } else {
            // Recovery: synthesize a literal false expression (matches Parser's
            // `return error.ParseFailed` precondition being avoided here — CstLower
            // consumes a clean tree but we still shield against malformed input).
            const lit = try self.arena.create(Ast.LiteralExpr);
            lit.* = .{ .loc = 0, .kind = .false_literal, .value = "false" };
            decl.* = .{ .expr = .{ .literal = lit } };
        }
        return decl;
    }

    // =====================================================================
    // Attributes
    // =====================================================================

    fn lowerAttributeList(self: *LowerCtx, cur: Cst.Cursor) !std.ArrayListUnmanaged(Ast.Attribute) {
        var list: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
        var w = self.walker(cur);
        while (w.peekNodeKind()) |k| {
            if (k != .attribute) break;
            const n = w.eatAnyNode().?;
            const attr = try self.lowerAttribute(self.nodeCursor(n));
            try list.append(self.arena, attr);
        }
        return list;
    }

    fn lowerAttribute(self: *LowerCtx, cur: Cst.Cursor) !Ast.Attribute {
        var w = self.walker(cur);
        var attr = Ast.Attribute{ .name = "", .args = .empty, .loc = 0, .span = self.nonTriviaSpan(cur.node) };
        if (w.eatToken(.at)) |token| attr.loc = self.tokenStart(token);
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            attr.name = self.tokenText(token);
        }
        if (w.eatNodeKind(.attribute_args)) |n| {
            attr.args = try self.lowerAttributeArgs(self.nodeCursor(n));
        }
        return attr;
    }

    fn lowerAttributeArgs(self: *LowerCtx, cur: Cst.Cursor) !std.ArrayListUnmanaged(Ast.Expr) {
        var args: std.ArrayListUnmanaged(Ast.Expr) = .empty;
        var w = self.walker(cur);
        _ = w.eatToken(.l_paren);
        while (true) {
            if (w.peekTokenTag()) |t| {
                if (t == .r_paren) break;
                if (t == .comma) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            if (w.eatAnyNode()) |n| {
                try args.append(self.arena, try self.lowerExpr(n));
            } else {
                break;
            }
        }
        _ = w.eatToken(.r_paren);
        return args;
    }

    // =====================================================================
    // Types
    // =====================================================================

    fn lowerType(self: *LowerCtx, n: Cst.NodeIndex) error{ OutOfMemory, InvalidCst }!Ast.Type {
        const kind = self.nodeKind(n);
        const cur = self.nodeCursor(n);
        const span = self.nonTriviaSpan(n);
        switch (kind) {
            .type_ident => {
                var w = self.walker(cur);
                var name: []const u8 = "";
                var loc: u32 = span.start;
                if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
                    name = self.tokenText(token);
                    loc = self.tokenStart(token);
                }
                const t = try self.arena.create(Ast.IdentType);
                t.* = .{ .name = name, .ref = .none, .loc = loc, .span = span };
                return .{ .ident = t };
            },
            .type_vec => return try self.lowerVecType(cur),
            .type_mat => return try self.lowerMatType(cur),
            .type_array => return try self.lowerArrayType(cur),
            .type_ptr => return try self.lowerPtrType(cur),
            .type_atomic => return try self.lowerAtomicType(cur),
            .type_sampler => return try self.lowerSamplerType(cur),
            .type_texture => return try self.lowerTextureType(cur),
            .error_tree => {
                const t = try self.arena.create(Ast.IdentType);
                t.* = .{ .name = "error", .ref = .none, .loc = span.start, .span = span };
                return .{ .ident = t };
            },
            else => return error.InvalidCst,
        }
    }

    fn lowerVecType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var name: []const u8 = "";
        var loc: u32 = span.start;
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            name = self.tokenText(token);
            loc = self.tokenStart(token);
        }
        const size: u8 = if (name.len >= 4) name[3] - '0' else 0;
        var elem: ?Ast.Type = null;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.VecType);
        t.* = .{ .size = size, .elem_type = elem, .loc = loc, .span = span };
        return .{ .vec = t };
    }

    fn lowerMatType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var name: []const u8 = "";
        var loc: u32 = span.start;
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            name = self.tokenText(token);
            loc = self.tokenStart(token);
        }
        const cols: u8 = if (name.len >= 6) name[3] - '0' else 0;
        const rows: u8 = if (name.len >= 6) name[5] - '0' else 0;
        var elem: ?Ast.Type = null;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.MatType);
        t.* = .{ .cols = cols, .rows = rows, .elem_type = elem, .loc = loc, .span = span };
        return .{ .mat = t };
    }

    fn lowerArrayType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.ident) orelse w.eatToken(.reserved_ident);
        var elem: ?Ast.Type = null;
        var size: ?Ast.Expr = null;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            if (tw.eatToken(.comma) != null) {
                if (tw.eatAnyNode()) |sn| size = try self.lowerExpr(sn);
            }
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.ArrayType);
        t.* = .{ .elem_type = elem, .size = size, .span = span };
        return .{ .array = t };
    }

    fn lowerPtrType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.ident) orelse w.eatToken(.reserved_ident);
        var addr: Ast.AddressSpace = .none;
        var elem: ?Ast.Type = null;
        var access: Ast.AccessMode = .none;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            if (tw.eatToken(.ident)) |token| addr = addressSpaceFromText(self.tokenText(token));
            _ = tw.eatToken(.comma);
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            if (tw.eatToken(.comma) != null) {
                if (tw.eatToken(.ident)) |token| access = accessModeFromText(self.tokenText(token));
            }
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.PtrType);
        t.* = .{
            .address_space = addr,
            .elem_type = elem orelse blk: {
                const ident = try self.arena.create(Ast.IdentType);
                ident.* = .{ .name = "", .ref = .none, .loc = span.start, .span = .empty };
                break :blk Ast.Type{ .ident = ident };
            },
            .access_mode = access,
            .span = span,
        };
        return .{ .ptr = t };
    }

    fn lowerAtomicType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var loc: u32 = span.start;
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| loc = self.tokenStart(token);
        var elem: ?Ast.Type = null;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.AtomicType);
        t.* = .{
            .elem_type = elem orelse blk: {
                const ident = try self.arena.create(Ast.IdentType);
                ident.* = .{ .name = "", .ref = .none, .loc = loc, .span = .empty };
                break :blk Ast.Type{ .ident = ident };
            },
            .loc = loc,
            .span = span,
        };
        return .{ .atomic = t };
    }

    fn lowerSamplerType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var is_comparison = false;
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            const name = self.tokenText(token);
            is_comparison = std.mem.eql(u8, name, "sampler_comparison");
        }
        const t = try self.arena.create(Ast.SamplerType);
        t.* = .{ .comparison = is_comparison, .span = span };
        return .{ .sampler = t };
    }

    fn lowerTextureType(self: *LowerCtx, cur: Cst.Cursor) !Ast.Type {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var name: []const u8 = "";
        if (w.eatToken(.ident) orelse w.eatToken(.reserved_ident)) |token| {
            name = self.tokenText(token);
        }
        const info = textureInfoFromName(name) orelse {
            const t = try self.arena.create(Ast.TextureType);
            t.* = .{ .kind = .sampled, .dimension = .@"2d", .span = span };
            return .{ .texture = t };
        };
        var sampled: ?Ast.Type = null;
        var texel_format: []const u8 = "";
        var access: Ast.AccessMode = .none;
        if (w.eatNodeKind(.template_args)) |tn| {
            var tw = self.walker(self.nodeCursor(tn));
            _ = tw.eatToken(.lt);
            switch (info.kind) {
                .sampled, .multisampled => {
                    if (tw.eatAnyNode()) |en| sampled = try self.lowerType(en);
                },
                .storage => {
                    if (tw.eatToken(.ident)) |token| texel_format = self.tokenText(token);
                    _ = tw.eatToken(.comma);
                    if (tw.eatToken(.ident)) |token| access = accessModeFromText(self.tokenText(token));
                },
                .depth, .depth_multisampled, .external => {},
            }
            _ = tw.eatToken(.gt);
        }
        const t = try self.arena.create(Ast.TextureType);
        t.* = .{
            .kind = info.kind,
            .dimension = info.dim,
            .sampled_type = sampled,
            .texel_format = texel_format,
            .access_mode = access,
            .span = span,
        };
        return .{ .texture = t };
    }

    // =====================================================================
    // Expressions
    // =====================================================================

    fn lowerExpr(self: *LowerCtx, n: Cst.NodeIndex) error{ OutOfMemory, InvalidCst }!Ast.Expr {
        const kind = self.nodeKind(n);
        const cur = self.nodeCursor(n);
        switch (kind) {
            .literal_expr => return try self.lowerLiteralExpr(cur),
            .ident_expr => return try self.lowerIdentExpr(cur),
            .binary_expr => return try self.lowerBinaryExpr(cur),
            .unary_expr => return try self.lowerUnaryExpr(cur),
            .call_expr => return try self.lowerCallExpr(cur),
            .index_expr => return try self.lowerIndexExpr(cur),
            .member_expr => return try self.lowerMemberExpr(cur),
            .paren_expr => return try self.lowerParenExpr(cur),
            .error_tree => {
                const lit = try self.arena.create(Ast.LiteralExpr);
                lit.* = .{ .loc = self.nonTriviaSpan(n).start, .kind = .false_literal, .value = "false" };
                return .{ .literal = lit };
            },
            else => return error.InvalidCst,
        }
    }

    fn lowerLiteralExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const token = w.eatAnyToken() orelse return error.InvalidCst;
        const tag = self.tokenTag(token);
        const loc = self.tokenStart(token);
        // Parser derives numeric literal text via its own `scanNumberText`
        // which stops at a different boundary than `Lexer.Token.end` in some
        // edge cases (e.g. `2.f` — Lexer says 3 chars, Parser says 1). To
        // stay byte-identical with the reference `Ast.LiteralExpr.value`,
        // mirror that logic for int/float literals.
        const value: []const u8 = switch (tag) {
            .int_literal, .float_literal => self.scanNumberText(loc),
            else => self.tokenText(token),
        };
        const node = try self.arena.create(Ast.LiteralExpr);
        node.* = .{ .loc = loc, .kind = tag, .value = value, .span = self.nonTriviaSpan(cur.node) };
        return .{ .literal = node };
    }

    /// Mirror of `Parser.scanNumberText` — same string both front-ends hand
    /// to `Ast.LiteralExpr.value`.
    fn scanNumberText(self: *const LowerCtx, start: u32) []const u8 {
        var pos = start;
        const src = self.cst.source;
        if (pos + 1 < src.len and src[pos] == '0' and (src[pos + 1] == 'x' or src[pos + 1] == 'X')) {
            pos += 2;
            while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                pos += 1;
                while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
            }
            if (pos < src.len and (src[pos] == 'p' or src[pos] == 'P')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
            }
        } else {
            while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                const nid = pos + 1 < src.len and Lexer.isDigit(src[pos + 1]);
                const nie = Lexer.peekIdentStart(src, pos + 1);
                const ae = pos + 1 >= src.len;
                // `1.f` / `1.h` — digit, dot, float-suffix, no trailing ident
                // chars — is a complete float literal (matches the lexer).
                const nfs = pos + 1 < src.len and
                    (src[pos + 1] == 'f' or src[pos + 1] == 'h') and
                    !Lexer.peekIdentContinue(src, pos + 2);
                if (nid or ae or !nie or nfs) {
                    pos += 1;
                    while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
                }
            }
            if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
            }
        }
        if (pos < src.len and (src[pos] == 'i' or src[pos] == 'u' or src[pos] == 'f' or src[pos] == 'h')) pos += 1;
        return src[start..pos];
    }

    fn lowerIdentExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const token = w.eatAnyToken() orelse return error.InvalidCst;
        // There may be a trailing `template_args` child if the source wrote
        // `vec3<f32>` without `(...)` — Parser accepts this as a lenient
        // ident reference; we mirror that and ignore the template_args.
        const node = try self.arena.create(Ast.IdentExpr);
        node.* = .{
            .loc = self.tokenStart(token),
            .name = self.tokenText(token),
            .ref = .none,
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .ident = node };
    }

    fn lowerBinaryExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const lhs_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op_tok = w.eatAnyToken() orelse return error.InvalidCst;
        const rhs_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op = binaryOpFromTag(self.tokenTag(op_tok)) orelse return error.InvalidCst;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{
            .loc = self.tokenStart(op_tok),
            .op = op,
            .left = try self.lowerExpr(lhs_n),
            .right = try self.lowerExpr(rhs_n),
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .binary = node };
    }

    fn lowerUnaryExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const op_tok = w.eatAnyToken() orelse return error.InvalidCst;
        const operand_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op = unaryOpFromTag(self.tokenTag(op_tok)) orelse return error.InvalidCst;
        const node = try self.arena.create(Ast.UnaryExpr);
        node.* = .{
            .loc = self.tokenStart(op_tok),
            .op = op,
            .operand = try self.lowerExpr(operand_n),
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .unary = node };
    }

    fn lowerCallExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        var func: ?Ast.Expr = null;
        var template_type: ?Ast.Type = null;

        // Three shapes, matching what `parsePrimaryExprInner` /
        // `parsePostfixExpr` emit:
        //   (a) plain call `foo(args)` — first child is an `ident_expr`
        //       node (the func); no template_args.
        //   (b) postfix call `obj.m(args)` — first child is a
        //       `member_expr` / `index_expr` / `call_expr` / etc. node.
        //   (c) templated constructor `vec3<f32>(args)` — first child is
        //       a raw ident TOKEN, followed by `template_args`. Parser
        //       clears `func` and stores a reconstructed vec/mat/array
        //       type in `template_type`.
        //   (d) bitcast `bitcast<T>(x)` — same as (c) but Parser keeps
        //       `func = IdentExpr("bitcast")` and stores the single inner
        //       type in `template_type`.
        if (w.peekElement()) |first| {
            if (first.asNode()) |n| {
                const nk = self.nodeKind(n);
                if (nk != .template_args) {
                    _ = w.eatAnyNode();
                    func = try self.lowerExpr(n);
                }
            } else if (first.asToken()) |token| {
                const tag = self.tokenTag(token);
                if (tag == .ident or tag == .reserved_ident) {
                    _ = w.eatAnyToken();
                    const name = self.tokenText(token);
                    const name_loc = self.tokenStart(token);
                    if (w.peekNodeKind()) |nk2| {
                        if (nk2 == .template_args) {
                            const tn = w.eatAnyNode().?;
                            if (std.mem.eql(u8, name, "bitcast")) {
                                const f = try self.arena.create(Ast.IdentExpr);
                                f.* = .{ .loc = name_loc, .name = name, .ref = .none };
                                func = .{ .ident = f };
                                template_type = try self.lowerTemplateArgsAsType(tn);
                            } else {
                                template_type = try self.reconstructTemplatedType(name, name_loc, tn);
                                // func stays null — Parser clears it for ctors
                            }
                        }
                    }
                    if (func == null and template_type == null) {
                        // Bare ident token with no template_args: build an
                        // IdentExpr as func.
                        const f = try self.arena.create(Ast.IdentExpr);
                        f.* = .{ .loc = name_loc, .name = name, .ref = .none };
                        func = .{ .ident = f };
                    }
                }
            }
        }

        // `(`
        var paren_loc: u32 = 0;
        if (w.eatToken(.l_paren)) |token| paren_loc = self.tokenStart(token);

        var args: std.ArrayListUnmanaged(Ast.Expr) = .empty;
        while (true) {
            if (w.peekTokenTag()) |t| {
                if (t == .r_paren) break;
                if (t == .comma) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            if (w.eatAnyNode()) |an| {
                try args.append(self.arena, try self.lowerExpr(an));
            } else break;
        }

        var end_loc: u32 = paren_loc +| 1;
        if (w.peekElement()) |el| {
            if (el.asToken()) |token| {
                if (self.tokenTag(token) == .r_paren) {
                    end_loc = self.tokenEnd(token);
                }
            }
        }
        _ = w.eatToken(.r_paren);

        const node = try self.arena.create(Ast.CallExpr);
        node.* = .{
            .loc = paren_loc,
            .end_loc = end_loc,
            .func = func,
            .template_type = template_type,
            .args = args,
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .call = node };
    }

    /// Reads a `template_args` node as a single `Ast.Type`. Used by call
    /// expressions that carry a `<T>` for bitcast or templated constructors.
    fn lowerTemplateArgsAsType(self: *LowerCtx, tn: Cst.NodeIndex) !Ast.Type {
        var tw = self.walker(self.nodeCursor(tn));
        _ = tw.eatToken(.lt);
        if (tw.eatAnyNode()) |n| {
            const t = try self.lowerType(n);
            _ = tw.eatToken(.gt);
            return t;
        }
        // Empty or malformed template_args: produce a blank ident.
        const ident = try self.arena.create(Ast.IdentType);
        const span = self.nonTriviaSpan(tn);
        ident.* = .{ .name = "", .ref = .none, .loc = span.start, .span = span };
        return .{ .ident = ident };
    }

    /// For a templated-constructor call like `vec3<f32>(args)`, build the
    /// `Ast.Type` that `Parser.parseTemplatedType` would have produced.
    /// `name` is the outer ident ("vec3" / "mat2x3" / "array" / …),
    /// `name_loc` its byte offset; `tn` is the `template_args` node.
    fn reconstructTemplatedType(
        self: *LowerCtx,
        name: []const u8,
        name_loc: u32,
        tn: Cst.NodeIndex,
    ) !Ast.Type {
        const args_span = self.nonTriviaSpan(tn);
        const type_span = Ast.Span{ .start = name_loc, .end = args_span.end };

        var tw = self.walker(self.nodeCursor(tn));
        _ = tw.eatToken(.lt);

        if (isVecName(name)) {
            const size = name[3] - '0';
            var elem: ?Ast.Type = null;
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            const t = try self.arena.create(Ast.VecType);
            t.* = .{ .size = size, .elem_type = elem, .loc = name_loc, .span = type_span };
            return .{ .vec = t };
        }
        if (isMatName(name)) {
            const cols = name[3] - '0';
            const rows = name[5] - '0';
            var elem: ?Ast.Type = null;
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            const t = try self.arena.create(Ast.MatType);
            t.* = .{ .cols = cols, .rows = rows, .elem_type = elem, .loc = name_loc, .span = type_span };
            return .{ .mat = t };
        }
        if (std.mem.eql(u8, name, "array")) {
            var elem: ?Ast.Type = null;
            if (tw.eatAnyNode()) |en| elem = try self.lowerType(en);
            var size: ?Ast.Expr = null;
            if (tw.eatToken(.comma) != null) {
                if (tw.eatAnyNode()) |sn| size = try self.lowerExpr(sn);
            }
            const t = try self.arena.create(Ast.ArrayType);
            t.* = .{ .elem_type = elem, .size = size, .span = type_span };
            return .{ .array = t };
        }
        // Fallback — shouldn't happen for well-formed input, but keeps
        // lowering total.
        const ident = try self.arena.create(Ast.IdentType);
        ident.* = .{ .name = name, .ref = .none, .loc = name_loc, .span = type_span };
        return .{ .ident = ident };
    }

    fn lowerIndexExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const base_n = w.eatAnyNode() orelse return error.InvalidCst;
        var bracket_loc: u32 = 0;
        if (w.eatToken(.l_bracket)) |token| bracket_loc = self.tokenStart(token);
        const idx_n = w.eatAnyNode() orelse return error.InvalidCst;
        var end_loc: u32 = bracket_loc +| 1;
        if (w.peekElement()) |el| {
            if (el.asToken()) |token| {
                if (self.tokenTag(token) == .r_bracket) end_loc = self.tokenEnd(token);
            }
        }
        _ = w.eatToken(.r_bracket);
        const node = try self.arena.create(Ast.IndexExpr);
        node.* = .{
            .loc = bracket_loc,
            .end_loc = end_loc,
            .base = try self.lowerExpr(base_n),
            .idx = try self.lowerExpr(idx_n),
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .index = node };
    }

    fn lowerMemberExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        const base_n = w.eatAnyNode() orelse return error.InvalidCst;
        var dot_loc: u32 = 0;
        if (w.eatToken(.dot)) |token| dot_loc = self.tokenStart(token);
        var member: []const u8 = "";
        if (w.eatAnyToken()) |token| member = self.tokenText(token);
        const node = try self.arena.create(Ast.MemberExpr);
        node.* = .{
            .loc = dot_loc,
            .base = try self.lowerExpr(base_n),
            .member_name = member,
            .span = self.nonTriviaSpan(cur.node),
        };
        return .{ .member = node };
    }

    fn lowerParenExpr(self: *LowerCtx, cur: Cst.Cursor) !Ast.Expr {
        var w = self.walker(cur);
        _ = w.eatToken(.l_paren);
        const inner = w.eatAnyNode() orelse return error.InvalidCst;
        _ = w.eatToken(.r_paren);
        const node = try self.arena.create(Ast.ParenExpr);
        node.* = .{ .expr = try self.lowerExpr(inner), .span = self.nonTriviaSpan(cur.node) };
        return .{ .paren = node };
    }

    // =====================================================================
    // Statements
    // =====================================================================

    fn lowerCompoundStmt(self: *LowerCtx, cur: Cst.Cursor) error{ OutOfMemory, InvalidCst }!*Ast.CompoundStmt {
        const stmt = try self.arena.create(Ast.CompoundStmt);
        stmt.* = .{ .stmts = .empty, .span = self.nonTriviaSpan(cur.node) };

        try self.pushScope(.block);

        var w = self.walker(cur);
        _ = w.eatToken(.l_brace);
        while (true) {
            // Bail if the walker is past all children — protects against
            // a malformed compound_stmt whose `r_brace` is missing. In
            // practice this never fires for a full parse, but guards the
            // incremental splice path where a bad CST shape would
            // otherwise spin forever on peekElement() == null.
            if (w.i >= w.children.len) break;
            if (w.peekTokenTag()) |t| {
                if (t == .r_brace or t == .eof) break;
                if (t == .semicolon) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            if (w.eatAnyNode()) |n| {
                if (try self.lowerStmt(n)) |s| try stmt.stmts.append(self.arena, s);
            } else if (w.eatAnyToken()) |_| {
                // advanced one token
            } else {
                break; // defensive — nothing eaten, so nothing would advance next iter
            }
        }
        _ = w.eatToken(.r_brace);

        self.popScope();
        return stmt;
    }

    fn lowerStmt(self: *LowerCtx, n: Cst.NodeIndex) error{ OutOfMemory, InvalidCst }!?Ast.Stmt {
        const kind = self.nodeKind(n);
        const cur = self.nodeCursor(n);
        return switch (kind) {
            .compound_stmt => .{ .compound = try self.lowerCompoundStmt(cur) },
            .return_stmt => .{ .@"return" = try self.lowerReturnStmt(cur) },
            .if_stmt => .{ .@"if" = try self.lowerIfStmt(cur) },
            .switch_stmt => .{ .@"switch" = try self.lowerSwitchStmt(cur) },
            .for_stmt => .{ .@"for" = try self.lowerForStmt(cur) },
            .while_stmt => .{ .@"while" = try self.lowerWhileStmt(cur) },
            .loop_stmt => .{ .loop = try self.lowerLoopStmt(cur) },
            .break_stmt => .{ .@"break" = try self.lowerBreakStmt(cur) },
            .break_if_stmt => .{ .break_if = try self.lowerBreakIfStmt(cur) },
            .continue_stmt => .{ .@"continue" = try self.lowerContinueStmt(cur) },
            .discard_stmt => .{ .discard = try self.lowerDiscardStmt(cur) },
            .assign_stmt => .{ .assign = try self.lowerAssignStmt(cur) },
            .incr_decr_stmt => .{ .incr_decr = try self.lowerIncrDecrStmt(cur) },
            .call_stmt => .{ .call = try self.lowerCallStmt(cur) },
            .decl_stmt => try self.lowerDeclStmt(cur),
            .error_tree => null,
            else => null,
        };
    }

    fn lowerReturnStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.ReturnStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var loc: u32 = span.start;
        if (w.eatToken(.keyword_return)) |token| loc = self.tokenStart(token);
        var value: ?Ast.Expr = null;
        if (w.peekElement()) |el| {
            if (el.asNode()) |n| {
                _ = w.eatAnyNode();
                value = try self.lowerExpr(n);
            }
        }
        const node = try self.arena.create(Ast.ReturnStmt);
        node.* = .{ .loc = loc, .value = value, .span = span };
        return node;
    }

    fn lowerIfStmt(self: *LowerCtx, cur: Cst.Cursor) error{ OutOfMemory, InvalidCst }!*Ast.IfStmt {
        // `parseIfStmt` iterates `else if` chains inside a single CST
        // `if_stmt` marker — so children are flat:
        //     keyword_if, cond, body, keyword_else, keyword_if, cond, body,
        //     keyword_else, final-body-or-if …
        // Each inner else-if becomes its own `Ast.IfStmt` (linked via
        // `else_branch`); every link in the chain shares the same end byte
        // (the end of the final body or final `else` compound), so we
        // backfill spans after walking the chain.
        var w = self.walker(cur);
        const chain_span = self.nonTriviaSpan(cur.node);

        var starts: std.ArrayListUnmanaged(struct { start: u32, ptr: *Ast.IfStmt }) = .empty;
        defer starts.deinit(self.arena);

        const root_if_tok = w.eatToken(.keyword_if) orelse return error.InvalidCst;
        const cond_n = w.eatAnyNode() orelse return error.InvalidCst;
        const body_n = w.eatNodeKind(.compound_stmt) orelse return error.InvalidCst;

        const root = try self.arena.create(Ast.IfStmt);
        root.* = .{
            .condition = try self.lowerExpr(cond_n),
            .body = try self.lowerCompoundStmt(self.nodeCursor(body_n)),
            .else_branch = null,
            .span = chain_span,
        };
        try starts.append(self.arena, .{ .start = self.tokenStart(root_if_tok), .ptr = root });

        var current = root;
        while (w.eatToken(.keyword_else) != null) {
            if (w.eatToken(.keyword_if)) |inner_if_tok| {
                const c = w.eatAnyNode() orelse break;
                const b = w.eatNodeKind(.compound_stmt) orelse break;
                const next = try self.arena.create(Ast.IfStmt);
                next.* = .{
                    .condition = try self.lowerExpr(c),
                    .body = try self.lowerCompoundStmt(self.nodeCursor(b)),
                    .else_branch = null,
                    .span = .empty,
                };
                current.else_branch = .{ .@"if" = next };
                current = next;
                try starts.append(self.arena, .{ .start = self.tokenStart(inner_if_tok), .ptr = next });
            } else if (w.eatNodeKind(.compound_stmt)) |b| {
                current.else_branch = .{ .compound = try self.lowerCompoundStmt(self.nodeCursor(b)) };
                break;
            } else break;
        }

        for (starts.items) |s| {
            s.ptr.span = .{ .start = s.start, .end = chain_span.end };
        }
        return root;
    }

    fn lowerSwitchStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.SwitchStmt {
        // Parser.parseSwitchStmt does not emit `switch_body`, `switch_case`,
        // or `case_selector` CST markers — all case/default keywords and
        // their selector expressions + compound bodies are loose children
        // of the `switch_stmt` node. Walk them linearly.
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.keyword_switch);
        const expr_n = w.eatAnyNode() orelse return error.InvalidCst;
        const expr = try self.lowerExpr(expr_n);

        var cases: std.ArrayListUnmanaged(Ast.SwitchCase) = .empty;
        _ = w.eatToken(.l_brace);
        while (true) {
            const t = w.peekTokenTag() orelse break;
            if (t == .r_brace or t == .eof) break;

            var c = Ast.SwitchCase{ .selectors = .empty, .body = undefined };
            if (w.eatToken(.keyword_default) != null) {
                // default — no selectors
            } else if (w.eatToken(.keyword_case) != null) {
                while (true) {
                    if (w.eatAnyNode()) |sn| {
                        try c.selectors.append(self.arena, try self.lowerExpr(sn));
                    } else break;
                    if (w.eatToken(.comma) == null) break;
                }
            } else {
                // Stray token — consume to make progress.
                _ = w.eatAnyToken();
                continue;
            }
            _ = w.eatToken(.colon);
            if (w.eatNodeKind(.compound_stmt)) |bn| {
                c.body = try self.lowerCompoundStmt(self.nodeCursor(bn));
            } else {
                c.body = try self.arena.create(Ast.CompoundStmt);
                c.body.* = .{ .stmts = .empty, .span = .empty };
            }
            try cases.append(self.arena, c);
        }
        _ = w.eatToken(.r_brace);

        const node = try self.arena.create(Ast.SwitchStmt);
        node.* = .{ .expr = expr, .cases = cases, .span = span };
        return node;
    }

    fn lowerForStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.ForStmt {
        // Parser.parseForStmt does NOT wrap init/update in stmt CST markers
        // — it calls `parseDeclaration` (which emits a `*_decl` node) or
        // `parseExpressionOrAssignment` (loose expression node + operator
        // tokens) directly. Reconstruct the corresponding `Ast.Stmt`
        // from those loose children here.
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.keyword_for);
        _ = w.eatToken(.l_paren);

        try self.pushScope(.block);

        const init_stmt = try self.lowerForInit(&w);
        _ = w.eatToken(.semicolon);

        var cond: ?Ast.Expr = null;
        if (w.peekElement()) |el| {
            if (el.asNode()) |n| {
                _ = w.eatAnyNode();
                cond = try self.lowerExpr(n);
            }
        }
        _ = w.eatToken(.semicolon);

        const update = try self.lowerForUpdate(&w);
        _ = w.eatToken(.r_paren);

        const body_n = w.eatNodeKind(.compound_stmt) orelse return error.InvalidCst;
        const body = try self.lowerCompoundStmt(self.nodeCursor(body_n));

        self.popScope();

        const node = try self.arena.create(Ast.ForStmt);
        node.* = .{
            .init_stmt = init_stmt,
            .condition = cond,
            .update = update,
            .body = body,
            .span = span,
        };
        return node;
    }

    /// Init of a `for (...)`: empty, a decl (var/let/const), or an
    /// expression+assignment-op / ++/-- / call. Parser inlines all of
    /// these without stmt markers; reconstruct the `Ast.Stmt` here.
    fn lowerForInit(self: *LowerCtx, w: *Walker) error{ OutOfMemory, InvalidCst }!?Ast.Stmt {
        if (w.peekTokenTag()) |t| if (t == .semicolon) return null;
        if (w.peekNodeKind()) |k| switch (k) {
            .const_decl, .var_decl, .let_decl => {
                const n = w.eatAnyNode().?;
                if (try self.lowerDecl(self.nodeCursor(n), k)) |decl| {
                    const ds = try self.arena.create(Ast.DeclStmt);
                    ds.* = .{ .decl = decl, .span = decl.declSpan() };
                    return Ast.Stmt{ .decl = ds };
                }
                return null;
            },
            else => {},
        };
        return try self.lowerLooseExprStmt(w, true);
    }

    /// Update of a `for (...)`: same shape as init minus decls and minus
    /// the trailing semicolon (caller eats the `)` instead).
    fn lowerForUpdate(self: *LowerCtx, w: *Walker) error{ OutOfMemory, InvalidCst }!?Ast.Stmt {
        if (w.peekTokenTag()) |t| if (t == .r_paren) return null;
        return try self.lowerLooseExprStmt(w, false);
    }

    /// Parse an expression followed by `++` / `--` / assign-op / (implicit
    /// call terminator). `expect_semicolon` = the caller will consume the
    /// trailing `;` afterwards; the for-update path sets this to false.
    fn lowerLooseExprStmt(self: *LowerCtx, w: *Walker, expect_semicolon: bool) error{ OutOfMemory, InvalidCst }!?Ast.Stmt {
        _ = expect_semicolon;
        const left_n = w.eatAnyNode() orelse return null;
        const left = try self.lowerExpr(left_n);
        const stmt_start = left.span().start;
        if (w.peekTokenTag()) |t| {
            if (t == .plus_plus or t == .minus_minus) {
                const token = w.eatAnyToken().?;
                const node = try self.arena.create(Ast.IncrDecrStmt);
                node.* = .{
                    .loc = self.tokenStart(token),
                    .expr = left,
                    .increment = t == .plus_plus,
                    .span = .{ .start = stmt_start, .end = self.tokenEnd(token) },
                };
                return Ast.Stmt{ .incr_decr = node };
            }
            if (assignOpFromTag(t)) |op| {
                const token = w.eatAnyToken().?;
                const right_n = w.eatAnyNode() orelse return null;
                const right = try self.lowerExpr(right_n);
                const node = try self.arena.create(Ast.AssignStmt);
                node.* = .{
                    .loc = self.tokenStart(token),
                    .op = op,
                    .left = left,
                    .right = right,
                    .span = .{ .start = stmt_start, .end = right.span().end },
                };
                return Ast.Stmt{ .assign = node };
            }
        }
        switch (left) {
            .call => |c| {
                const node = try self.arena.create(Ast.CallStmt);
                node.* = .{ .call = c, .span = left.span() };
                return Ast.Stmt{ .call = node };
            },
            else => return null,
        }
    }

    fn lowerWhileStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.WhileStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.keyword_while);
        const cond_n = w.eatAnyNode() orelse return error.InvalidCst;
        const body_n = w.eatNodeKind(.compound_stmt) orelse return error.InvalidCst;
        const node = try self.arena.create(Ast.WhileStmt);
        node.* = .{
            .condition = try self.lowerExpr(cond_n),
            .body = try self.lowerCompoundStmt(self.nodeCursor(body_n)),
            .span = span,
        };
        return node;
    }

    fn lowerLoopStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.LoopStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.keyword_loop);
        const body_n = w.eatNodeKind(.compound_stmt) orelse return error.InvalidCst;
        // Spec form (WGSL §8.8): `continuing` lives as the final statement
        // inside the body compound. Siphon it out while the body scope is
        // active so its scope slots in correctly between body and the next
        // sibling — mirrors how `Parser.parseLoopBody` pushes `body →
        // continuing` into `scopes_in_order`.
        var continuing: ?*Ast.CompoundStmt = null;
        const body = try self.lowerLoopBody(self.nodeCursor(body_n), &continuing);
        // Legacy form — `continuing_stmt` sits as a sibling of the body
        // compound (older `loop { body } continuing { cont }` shape).
        if (continuing == null) {
            if (w.eatNodeKind(.continuing_stmt)) |cn| {
                continuing = try self.lowerContinuingStmtNode(cn);
            }
        }
        const node = try self.arena.create(Ast.LoopStmt);
        node.* = .{
            .body = body,
            .continuing = continuing,
            .span = span,
        };
        return node;
    }

    /// Like `lowerCompoundStmt` but also siphons a trailing `.continuing_stmt`
    /// child out into `out_continuing`, lowered while the body's block scope
    /// is still the active scope so the continuing scope slots in after body
    /// in `scopes_in_order` — exactly how `Parser.parseLoopBody` builds it.
    fn lowerLoopBody(self: *LowerCtx, cur: Cst.Cursor, out_continuing: *?*Ast.CompoundStmt) error{ OutOfMemory, InvalidCst }!*Ast.CompoundStmt {
        const stmt = try self.arena.create(Ast.CompoundStmt);
        stmt.* = .{ .stmts = .empty, .span = self.nonTriviaSpan(cur.node) };

        try self.pushScope(.block);

        var w = self.walker(cur);
        _ = w.eatToken(.l_brace);
        while (true) {
            if (w.i >= w.children.len) break;
            if (w.peekTokenTag()) |t| {
                if (t == .r_brace or t == .eof) break;
                if (t == .semicolon) {
                    _ = w.eatAnyToken();
                    continue;
                }
            }
            if (w.eatAnyNode()) |n| {
                if (self.nodeKind(n) == .continuing_stmt) {
                    out_continuing.* = try self.lowerContinuingStmtNode(n);
                    continue;
                }
                if (try self.lowerStmt(n)) |s| try stmt.stmts.append(self.arena, s);
            } else if (w.eatAnyToken()) |_| {
                // advanced one token
            } else {
                break;
            }
        }
        _ = w.eatToken(.r_brace);

        self.popScope();
        return stmt;
    }

    fn lowerContinuingStmtNode(self: *LowerCtx, cn: Cst.NodeIndex) !*Ast.CompoundStmt {
        var cw = self.walker(self.nodeCursor(cn));
        _ = cw.eatToken(.keyword_continuing);
        if (cw.eatNodeKind(.compound_stmt)) |cbody| {
            return self.lowerCompoundStmt(self.nodeCursor(cbody));
        }
        const empty = try self.arena.create(Ast.CompoundStmt);
        empty.* = .{ .stmts = .empty };
        return empty;
    }

    fn lowerBreakStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.BreakStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var loc: u32 = span.start;
        if (w.eatToken(.keyword_break)) |token| loc = self.tokenStart(token);
        const node = try self.arena.create(Ast.BreakStmt);
        node.* = .{ .loc = loc, .span = span };
        return node;
    }

    fn lowerBreakIfStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.BreakIfStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        _ = w.eatToken(.keyword_break);
        _ = w.eatToken(.keyword_if);
        const cond_n = w.eatAnyNode() orelse return error.InvalidCst;
        const node = try self.arena.create(Ast.BreakIfStmt);
        node.* = .{ .condition = try self.lowerExpr(cond_n), .span = span };
        return node;
    }

    fn lowerContinueStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.ContinueStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var loc: u32 = span.start;
        if (w.eatToken(.keyword_continue)) |token| loc = self.tokenStart(token);
        const node = try self.arena.create(Ast.ContinueStmt);
        node.* = .{ .loc = loc, .span = span };
        return node;
    }

    fn lowerDiscardStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.DiscardStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        var loc: u32 = span.start;
        if (w.eatToken(.keyword_discard)) |token| loc = self.tokenStart(token);
        const node = try self.arena.create(Ast.DiscardStmt);
        node.* = .{ .loc = loc, .span = span };
        return node;
    }

    fn lowerAssignStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.AssignStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        const lhs_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op_tok = w.eatAnyToken() orelse return error.InvalidCst;
        const rhs_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op = assignOpFromTag(self.tokenTag(op_tok)) orelse .simple;
        const node = try self.arena.create(Ast.AssignStmt);
        node.* = .{
            .loc = self.tokenStart(op_tok),
            .op = op,
            .left = try self.lowerExpr(lhs_n),
            .right = try self.lowerExpr(rhs_n),
            .span = span,
        };
        return node;
    }

    fn lowerIncrDecrStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.IncrDecrStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        const expr_n = w.eatAnyNode() orelse return error.InvalidCst;
        const op_tok = w.eatAnyToken() orelse return error.InvalidCst;
        const increment = self.tokenTag(op_tok) == .plus_plus;
        const node = try self.arena.create(Ast.IncrDecrStmt);
        node.* = .{
            .loc = self.tokenStart(op_tok),
            .expr = try self.lowerExpr(expr_n),
            .increment = increment,
            .span = span,
        };
        return node;
    }

    fn lowerCallStmt(self: *LowerCtx, cur: Cst.Cursor) !*Ast.CallStmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        const call_n = w.eatAnyNode() orelse return error.InvalidCst;
        const call_expr = try self.lowerExpr(call_n);
        const call_ptr = switch (call_expr) {
            .call => |c| c,
            else => return error.InvalidCst,
        };
        const node = try self.arena.create(Ast.CallStmt);
        node.* = .{ .call = call_ptr, .span = span };
        return node;
    }

    fn lowerDeclStmt(self: *LowerCtx, cur: Cst.Cursor) !?Ast.Stmt {
        var w = self.walker(cur);
        const span = self.nonTriviaSpan(cur.node);
        const n = w.eatAnyNode() orelse return null;
        const k = self.nodeKind(n);
        const decl = try self.lowerDecl(self.nodeCursor(n), k) orelse return null;
        const node = try self.arena.create(Ast.DeclStmt);
        node.* = .{ .decl = decl, .span = span };
        return Ast.Stmt{ .decl = node };
    }
};

// =========================================================================
// Tag → AST enum helpers
// =========================================================================

fn binaryOpFromTag(t: Tag) ?Ast.BinaryOp {
    return switch (t) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .amp => .@"and",
        .pipe => .@"or",
        .caret => .xor,
        .lt_lt => .shl,
        .gt_gt => .shr,
        .amp_amp => .logical_and,
        .pipe_pipe => .logical_or,
        .eq_eq => .eq,
        .bang_eq => .ne,
        .lt => .lt,
        .lt_eq => .le,
        .gt => .gt,
        .gt_eq => .ge,
        else => null,
    };
}

fn unaryOpFromTag(t: Tag) ?Ast.UnaryOp {
    return switch (t) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        .star => .deref,
        .amp => .addr,
        else => null,
    };
}

fn assignOpFromTag(t: Tag) ?Ast.AssignOp {
    return switch (t) {
        .eq => .simple,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .@"and",
        .pipe_eq => .@"or",
        .caret_eq => .xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => null,
    };
}

fn addressSpaceFromText(text: []const u8) Ast.AddressSpace {
    const map = std.StaticStringMap(Ast.AddressSpace).initComptime(.{
        .{ "function", .function },
        .{ "private", .private },
        .{ "workgroup", .workgroup },
        .{ "uniform", .uniform },
        .{ "storage", .storage },
    });
    return map.get(text) orelse .none;
}

fn accessModeFromText(text: []const u8) Ast.AccessMode {
    const map = std.StaticStringMap(Ast.AccessMode).initComptime(.{
        .{ "read", .read },
        .{ "write", .write },
        .{ "read_write", .read_write },
    });
    return map.get(text) orelse .none;
}

const TextureInfo = struct { kind: Ast.TextureKind, dim: Ast.TextureDimension };

fn isVecName(name: []const u8) bool {
    return name.len == 4 and std.mem.eql(u8, name[0..3], "vec") and name[3] >= '2' and name[3] <= '4';
}

fn isMatName(name: []const u8) bool {
    return name.len == 6 and std.mem.eql(u8, name[0..3], "mat") and name[4] == 'x';
}

fn textureInfoFromName(name: []const u8) ?TextureInfo {
    const map = std.StaticStringMap(TextureInfo).initComptime(.{
        .{ "texture_1d", TextureInfo{ .kind = .sampled, .dim = .@"1d" } },
        .{ "texture_2d", TextureInfo{ .kind = .sampled, .dim = .@"2d" } },
        .{ "texture_2d_array", TextureInfo{ .kind = .sampled, .dim = .@"2d_array" } },
        .{ "texture_3d", TextureInfo{ .kind = .sampled, .dim = .@"3d" } },
        .{ "texture_cube", TextureInfo{ .kind = .sampled, .dim = .cube } },
        .{ "texture_cube_array", TextureInfo{ .kind = .sampled, .dim = .cube_array } },
        .{ "texture_multisampled_2d", TextureInfo{ .kind = .multisampled, .dim = .@"2d" } },
        .{ "texture_external", TextureInfo{ .kind = .external, .dim = .@"2d" } },
        .{ "texture_storage_1d", TextureInfo{ .kind = .storage, .dim = .@"1d" } },
        .{ "texture_storage_2d", TextureInfo{ .kind = .storage, .dim = .@"2d" } },
        .{ "texture_storage_2d_array", TextureInfo{ .kind = .storage, .dim = .@"2d_array" } },
        .{ "texture_storage_3d", TextureInfo{ .kind = .storage, .dim = .@"3d" } },
        .{ "texture_depth_2d", TextureInfo{ .kind = .depth, .dim = .@"2d" } },
        .{ "texture_depth_2d_array", TextureInfo{ .kind = .depth, .dim = .@"2d_array" } },
        .{ "texture_depth_cube", TextureInfo{ .kind = .depth, .dim = .cube } },
        .{ "texture_depth_cube_array", TextureInfo{ .kind = .depth, .dim = .cube_array } },
        .{ "texture_depth_multisampled_2d", TextureInfo{ .kind = .depth_multisampled, .dim = .@"2d" } },
    });
    return map.get(name);
}

// =========================================================================
// Tests
// =========================================================================

test {
    _ = @import("Cst.zig");
}
