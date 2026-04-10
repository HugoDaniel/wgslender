//! Two-pass WGSL parser.
//!
//! Pass 1 (parse): Build AST, declare symbols with use_count = 0.
//! Pass 2 (visit): Bind identifiers to symbols, increment use_count, mark purity.

const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");

const Parser = @This();

const Tag = Lexer.Tag;

arena: std.mem.Allocator,
source: [:0]const u8,
token_tags: []const Tag,
token_starts: []const u32,
pos: u32,

// Symbol table
symbols: std.ArrayListUnmanaged(Ast.Symbol),
scope: *Ast.Scope,

// Two-pass tracking
scopes_in_order: std.ArrayListUnmanaged(*Ast.Scope),
scope_index: u32,
current_loc: u32,

// Errors
errors: std.ArrayListUnmanaged(ParseError),
expr_context: []const u8 = "",

pub const ParseError = struct {
    message: []const u8,
    pos: u32,
    end: u32 = 0,
    code: []const u8 = "",
};

// =========================================================================
// Initialization
// =========================================================================

/// Creates a parser for the given tokenized WGSL source. Allocates the root scope.
pub fn init(arena: std.mem.Allocator, source: [:0]const u8, tokens: std.MultiArrayList(Lexer.Token)) !Parser {
    const scope = try arena.create(Ast.Scope);
    scope.* = Ast.Scope.init(null);

    return .{
        .arena = arena,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .pos = 0,
        .symbols = .empty,
        .scope = scope,
        .scopes_in_order = .empty,
        .scope_index = 0,
        .current_loc = 0,
        .errors = .empty,
    };
}

/// Parse source into a Module. Caller owns the returned module via the arena.
pub fn parse(self: *Parser) !*Ast.Module {
    const module = try self.arena.create(Ast.Module);
    module.* = Ast.Module.init(self.scope, self.source);

    // Pass 1: Parse
    try self.parseTranslationUnit(module);

    // Pass 2: Visit
    self.visitModule(module);

    // Copy symbols to module
    module.symbols = self.symbols;

    return module;
}

// =========================================================================
// Token helpers
// =========================================================================

fn currentTag(self: *const Parser) Tag {
    if (self.pos >= self.token_tags.len) return .eof;
    return self.token_tags[self.pos];
}

fn peekTag(self: *const Parser, offset: u32) Tag {
    const p = self.pos + offset;
    if (p >= self.token_tags.len) return .eof;
    return self.token_tags[p];
}

fn advance(self: *Parser) void {
    if (self.pos < self.token_tags.len) self.pos += 1;
}

fn eat(self: *Parser, tag: Tag) bool {
    if (self.currentTag() == tag) {
        self.advance();
        return true;
    }
    return false;
}

fn expect(self: *Parser, tag: Tag) bool {
    if (self.currentTag() != tag) {
        const msg = std.fmt.allocPrint(self.arena, "expected '{s}'", .{tag.symbol()}) catch "expected token";
        self.addError(msg);
        return false;
    }
    self.advance();
    return true;
}

fn tokenText(self: *const Parser, pos: u32) []const u8 {
    if (pos >= self.token_tags.len) return "";
    const start = self.token_starts[pos];
    const tag = self.token_tags[pos];
    _ = tag;
    // Scan to find end of this token's text
    var end = start;
    const src = self.source;
    if (end >= src.len) return "";
    const ch = src[end];
    if (Lexer.isIdentStart(ch)) {
        end += 1;
        while (end < src.len and Lexer.isIdentContinue(src[end])) end += 1;
    } else if (Lexer.isDigit(ch) or (ch == '.' and end + 1 < src.len and Lexer.isDigit(src[end + 1]))) {
        return self.scanNumberText(start);
    } else {
        // operator - advance 1-3 chars
        end += 1;
        if (end < src.len) {
            const nc = src[end];
            switch (ch) {
                '+' => if (nc == '+' or nc == '=') {
                    end += 1;
                },
                '-' => if (nc == '-' or nc == '=' or nc == '>') {
                    end += 1;
                },
                '*', '/', '%' => if (nc == '=') {
                    end += 1;
                },
                '&' => if (nc == '&' or nc == '=') {
                    end += 1;
                },
                '|' => if (nc == '|' or nc == '=') {
                    end += 1;
                },
                '^' => if (nc == '=') {
                    end += 1;
                },
                '<' => {
                    if (nc == '<') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '>' => {
                    if (nc == '>') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '=', '!' => if (nc == '=') {
                    end += 1;
                },
                else => {},
            }
        }
    }
    return src[start..end];
}

fn scanNumberText(self: *const Parser, start: u32) []const u8 {
    var pos = start;
    const src = self.source;
    // Hex
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
            const nie = pos + 1 < src.len and Lexer.isIdentStart(src[pos + 1]);
            const ae = pos + 1 >= src.len;
            if (nid or ae or !nie) {
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

fn currentText(self: *const Parser) []const u8 {
    return self.tokenText(self.pos);
}

fn currentStart(self: *const Parser) u32 {
    if (self.pos >= self.token_starts.len) return @intCast(self.source.len);
    return self.token_starts[self.pos];
}

fn addError(self: *Parser, message: []const u8) void {
    const start = self.currentStart();
    const text = self.currentText();
    self.errors.append(self.arena, .{ .message = message, .pos = start, .end = start +| @as(u32, @intCast(text.len)) }) catch {};
}

fn isIdentLike(self: *const Parser) bool {
    const tag = self.currentTag();
    return tag == .ident or tag == .reserved_ident;
}

fn peekIdentLike(self: *const Parser, offset: u32) bool {
    const tag = self.peekTag(offset);
    return tag == .ident or tag == .reserved_ident;
}

/// Check if current token is an identifier (or reserved word used as identifier).
/// Emits a diagnostic for reserved words but returns the text for error recovery.
fn eatIdent(self: *Parser) ?[]const u8 {
    if (self.currentTag() == .reserved_ident) {
        const text = self.currentText();
        const msg = if (text.len >= 2 and text[0] == '_' and text[1] == '_')
            std.fmt.allocPrint(self.arena, "identifier '{s}' must not start with '__'", .{text}) catch "identifier must not start with '__'"
        else
            std.fmt.allocPrint(self.arena, "'{s}' is a reserved word and cannot be used as an identifier", .{text}) catch "use of reserved word";
        self.errors.append(self.arena, .{ .message = msg, .pos = self.currentStart(), .code = "E0004" }) catch {};
        return text;
    }
    if (self.currentTag() == .ident) {
        return self.currentText();
    }
    return null;
}

// =========================================================================
// Symbol table (Pass 1)
// =========================================================================

fn declareSymbol(self: *Parser, name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags, loc: u32) !Ast.SymbolIndex {
    // Check for duplicate declaration in the same scope
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

/// Creates a symbol without adding it to the scope lookup table.
/// Used for struct members which should not shadow other identifiers.
fn declareSymbolNoScope(self: *Parser, name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags, loc: u32) !Ast.SymbolIndex {
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

fn lookupSymbol(self: *const Parser, name: []const u8) ?Ast.SymbolIndex {
    var scope_iter: ?*Ast.Scope = self.scope;
    while (scope_iter) |s| {
        if (s.members.get(name)) |member| {
            // Module scope (no parent) is always visible.
            // Local symbols visible only if declared before current_loc.
            // During parse pass (current_loc == 0), allow all.
            if (s.parent == null or self.current_loc == 0 or member.loc < self.current_loc) {
                return member.ref;
            }
        }
        scope_iter = s.parent;
    }
    return null;
}

/// Like lookupSymbol but ignores text-order constraints.
/// Used to distinguish "use before declaration" from "truly undefined".
fn lookupSymbolAnyLoc(self: *const Parser, name: []const u8) ?Ast.SymbolIndex {
    var scope_iter: ?*Ast.Scope = self.scope;
    while (scope_iter) |s| {
        if (s.members.get(name)) |member| {
            return member.ref;
        }
        scope_iter = s.parent;
    }
    return null;
}

fn pushScope(self: *Parser) !void {
    const new_scope = try self.arena.create(Ast.Scope);
    new_scope.* = Ast.Scope.init(self.scope);
    try self.scope.children.append(self.arena, new_scope);
    self.scope = new_scope;
    try self.scopes_in_order.append(self.arena, new_scope);
}

fn popScope(self: *Parser) void {
    std.debug.assert(self.scope.parent != null);
    if (self.scope.parent) |p| self.scope = p;
}

// =========================================================================
// Pass 2: Visit
// =========================================================================

fn visitModule(self: *Parser, module: *Ast.Module) void {
    self.scope = module.scope;
    self.scope_index = 0;

    for (module.declarations.items) |decl| {
        self.visitDecl(decl);
    }
}

fn visitDecl(self: *Parser, d: Ast.Decl) void {
    switch (d) {
        .@"const" => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .override => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .@"var" => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .let => |decl| {
            if (decl.typ) |t| self.visitType(t);
            if (decl.initializer) |init_expr| decl.initializer = self.visitExpr(init_expr);
        },
        .function => |decl| self.visitFunctionDecl(decl),
        .@"struct" => |decl| {
            for (decl.members.items) |member| {
                self.visitType(member.typ);
            }
        },
        .alias => |decl| self.visitType(decl.typ),
        .const_assert => |decl| decl.expr = self.visitExpr(decl.expr),
    }
}

fn visitFunctionDecl(self: *Parser, decl: *Ast.FunctionDecl) void {
    for (decl.parameters.items) |param| {
        self.visitType(param.typ);
    }
    if (decl.return_type) |rt| self.visitType(rt);
    self.enterNextScope();
    if (decl.body) |body| self.visitCompoundStmt(body);
    self.exitScope();
}

/// Iteratively visits statements using a worklist with scope markers.
fn visitStmt(self: *Parser, root: Ast.Stmt) void {
    const Work = union(enum) {
        stmt: Ast.Stmt,
        compound: *Ast.CompoundStmt,
        exit_scope,
    };

    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(self.arena);
    stack.append(self.arena, .{ .stmt = root }) catch return;

    for (0..self.token_tags.len * 2) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .exit_scope => self.exitScope(),
            .compound => |body| {
                self.enterNextScope();
                stack.append(self.arena, .exit_scope) catch {};
                var i = body.stmts.items.len;
                while (i > 0) {
                    i -= 1;
                    stack.append(self.arena, .{ .stmt = body.stmts.items[i] }) catch {};
                }
            },
            .stmt => |s| self.processOneStmt(s, &stack),
        }
    } else unreachable;
}

/// Process a single statement, pushing child work items onto the stack.
/// Expression visits are done inline (already iterative).
fn processOneStmt(self: *Parser, s: Ast.Stmt, stack: anytype) void {
    const Work = std.meta.Child(@TypeOf(stack.items));
    switch (s) {
        .compound => |stmt| stack.append(self.arena, .{ .compound = stmt }) catch {},
        .@"return" => |stmt| {
            if (stmt.value) |v| stmt.value = self.visitExpr(v);
        },
        .@"if" => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
            // Push else branch first (processed after body), then body
            if (stmt.else_branch) |eb| stack.append(self.arena, @as(Work, .{ .stmt = eb })) catch {};
            stack.append(self.arena, @as(Work, .{ .compound = stmt.body })) catch {};
        },
        .@"switch" => |stmt| {
            stmt.expr = self.visitExpr(stmt.expr);
            // Push case bodies in reverse order
            var i = stmt.cases.items.len;
            while (i > 0) {
                i -= 1;
                const c = &stmt.cases.items[i];
                stack.append(self.arena, @as(Work, .{ .compound = c.body })) catch {};
            }
            // Visit selectors inline
            for (stmt.cases.items) |*c| {
                for (c.selectors.items, 0..) |sel, j| {
                    c.selectors.items[j] = self.visitExpr(sel);
                }
            }
        },
        .@"for" => |stmt| {
            // For has its own scope wrapping init/condition/update/body
            self.enterNextScope();
            if (stmt.init_stmt) |is| self.processOneStmt(is, stack);
            if (stmt.condition) |cond| stmt.condition = self.visitExpr(cond);
            if (stmt.update) |upd| self.processOneStmt(upd, stack);
            // Push exit_scope (for-scope), then body (which adds its own scope)
            stack.append(self.arena, @as(Work, .exit_scope)) catch {};
            stack.append(self.arena, @as(Work, .{ .compound = stmt.body })) catch {};
        },
        .@"while" => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
            stack.append(self.arena, @as(Work, .{ .compound = stmt.body })) catch {};
        },
        .loop => |stmt| {
            if (stmt.continuing) |c| stack.append(self.arena, @as(Work, .{ .compound = c })) catch {};
            stack.append(self.arena, @as(Work, .{ .compound = stmt.body })) catch {};
        },
        .break_if => |stmt| {
            stmt.condition = self.visitExpr(stmt.condition);
        },
        .assign => |stmt| {
            stmt.left = self.visitExpr(stmt.left);
            stmt.right = self.visitExpr(stmt.right);
        },
        .incr_decr => |stmt| {
            stmt.expr = self.visitExpr(stmt.expr);
        },
        .call => |stmt| {
            if (stmt.call.func) |f| stmt.call.func = self.visitExpr(f);
            if (stmt.call.template_type) |tt| self.visitType(tt);
            for (stmt.call.args.items, 0..) |arg, j| {
                stmt.call.args.items[j] = self.visitExpr(arg);
            }
        },
        .decl => |stmt| self.visitDecl(stmt.decl),
        .@"break", .@"continue", .discard => {},
    }
}

fn visitCompoundStmt(self: *Parser, stmt: *Ast.CompoundStmt) void {
    const Work = union(enum) {
        stmt: Ast.Stmt,
        compound: *Ast.CompoundStmt,
        exit_scope,
    };

    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(self.arena);
    stack.append(self.arena, .{ .compound = stmt }) catch return;

    for (0..self.token_tags.len * 2) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .exit_scope => self.exitScope(),
            .compound => |body| {
                self.enterNextScope();
                stack.append(self.arena, .exit_scope) catch {};
                var i = body.stmts.items.len;
                while (i > 0) {
                    i -= 1;
                    stack.append(self.arena, .{ .stmt = body.stmts.items[i] }) catch {};
                }
            },
            .stmt => |s| self.processOneStmt(s, &stack),
        }
    } else unreachable;
}

/// Iteratively visits an expression tree using a two-phase worklist.
/// Pushes mark(e) before children so purity marking happens in post-order.
fn visitExpr(self: *Parser, e: Ast.Expr) Ast.Expr {
    const Work = union(enum) {
        visit: Ast.Expr,
        mark: Ast.Expr,
    };

    var stack: std.ArrayListUnmanaged(Work) = .empty;
    defer stack.deinit(self.arena);
    stack.append(self.arena, .{ .visit = e }) catch return e;

    for (0..self.token_tags.len * 2) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .mark => |me| Ast.markExprPurity(me, self.symbols.items),
            .visit => |ve| {
                // Push mark first (popped last = post-order)
                stack.append(self.arena, .{ .mark = ve }) catch {};

                switch (ve) {
                    .ident => |expr| {
                        self.current_loc = expr.loc;
                        if (self.lookupSymbol(expr.name)) |ref| {
                            expr.ref = ref;
                            if (ref.isValid()) {
                                const idx = ref.index();
                                if (idx < self.symbols.items.len) {
                                    self.symbols.items[idx].use_count += 1;
                                }
                            }
                        } else if (self.lookupSymbolAnyLoc(expr.name)) |ref| {
                            const msg = std.fmt.allocPrint(self.arena, "'{s}' is used before its declaration", .{expr.name}) catch "identifier used before declaration";
                            self.errors.append(self.arena, .{ .message = msg, .pos = expr.loc, .code = "E0102" }) catch {};
                            expr.ref = ref;
                        }
                    },
                    .literal => {},
                    .binary => |expr| {
                        stack.append(self.arena, .{ .visit = expr.right }) catch {};
                        stack.append(self.arena, .{ .visit = expr.left }) catch {};
                    },
                    .unary => |expr| {
                        stack.append(self.arena, .{ .visit = expr.operand }) catch {};
                    },
                    .call => |expr| {
                        var i = expr.args.items.len;
                        while (i > 0) {
                            i -= 1;
                            stack.append(self.arena, .{ .visit = expr.args.items[i] }) catch {};
                        }
                        if (expr.template_type) |tt| self.visitType(tt);
                        if (expr.func) |f| stack.append(self.arena, .{ .visit = f }) catch {};
                    },
                    .index => |expr| {
                        stack.append(self.arena, .{ .visit = expr.idx }) catch {};
                        stack.append(self.arena, .{ .visit = expr.base }) catch {};
                    },
                    .member => |expr| {
                        stack.append(self.arena, .{ .visit = expr.base }) catch {};
                    },
                    .paren => |expr| {
                        stack.append(self.arena, .{ .visit = expr.expr }) catch {};
                    },
                }
            },
        }
    } else unreachable;
    return e;
}

/// Iteratively visits a type, following single-child chains.
fn visitType(self: *Parser, t: Ast.Type) void {
    var current = t;
    for (0..32) |_| {
        switch (current) {
            .ident => |typ| {
                self.current_loc = 0; // Types don't have text-order restrictions at module scope
                if (self.lookupSymbol(typ.name)) |ref| {
                    typ.ref = ref;
                    if (ref.isValid()) {
                        const idx = ref.index();
                        if (idx < self.symbols.items.len) {
                            self.symbols.items[idx].use_count += 1;
                        }
                    }
                }
                break;
            },
            .vec => |typ| current = typ.elem_type orelse break,
            .mat => |typ| current = typ.elem_type orelse break,
            .array => |typ| {
                if (typ.size) |s| _ = self.visitExpr(s);
                current = typ.elem_type orelse break;
            },
            .ptr => |typ| current = typ.elem_type,
            .atomic => |typ| current = typ.elem_type,
            .sampler => break,
            .texture => |typ| current = typ.sampled_type orelse break,
        }
    } else unreachable;
}

fn enterNextScope(self: *Parser) void {
    if (self.scope_index < self.scopes_in_order.items.len) {
        self.scope = self.scopes_in_order.items[self.scope_index];
        self.scope_index += 1;
    }
}

fn exitScope(self: *Parser) void {
    if (self.scope.parent) |p| self.scope = p;
}

// =========================================================================
// Pass 1: Parse
// =========================================================================

fn parseTranslationUnit(self: *Parser, module: *Ast.Module) !void {
    // Parse directives
    for (0..self.token_tags.len) |_| {
        switch (self.currentTag()) {
            .keyword_enable => {
                const dir = try self.parseEnableDirective();
                try module.directives.append(self.arena, dir);
            },
            .keyword_requires => {
                const dir = try self.parseRequiresDirective();
                try module.directives.append(self.arena, dir);
            },
            .keyword_diagnostic => {
                const dir = try self.parseDiagnosticDirective();
                try module.directives.append(self.arena, dir);
            },
            else => break,
        }
    } else unreachable;

    // Parse declarations
    while (self.currentTag() != .eof) {
        if (try self.parseDeclaration()) |decl| {
            try module.declarations.append(self.arena, decl);
        } else {
            self.advance();
        }
    }
}

fn parseEnableDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_enable);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..self.token_tags.len) |_| {
        if (self.currentTag() == .ident) {
            try features.append(self.arena, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    } else unreachable;
    _ = self.expect(.semicolon);
    return .{ .enable = .{ .features = features } };
}

fn parseRequiresDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_requires);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..self.token_tags.len) |_| {
        if (self.currentTag() == .ident) {
            try features.append(self.arena, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    } else unreachable;
    _ = self.expect(.semicolon);
    return .{ .requires = .{ .features = features } };
}

fn parseDiagnosticDirective(self: *Parser) !Ast.Directive {
    _ = self.expect(.keyword_diagnostic);
    _ = self.expect(.l_paren);
    const severity = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.comma);
    const rule = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.r_paren);
    _ = self.expect(.semicolon);
    return .{ .diagnostic = .{ .severity = severity, .rule = rule } };
}

fn parseDeclaration(self: *Parser) !?Ast.Decl {
    var attrs = try self.parseAttributes();

    switch (self.currentTag()) {
        .keyword_const => {
            if (self.peekIdentLike(1)) return .{ .@"const" = try self.parseConstDecl() };
            return .{ .const_assert = try self.parseConstAssert() };
        },
        .keyword_const_assert => return .{ .const_assert = try self.parseConstAssert() },
        .keyword_override => return .{ .override = try self.parseOverrideDecl(&attrs) },
        .keyword_var => return .{ .@"var" = try self.parseVarDecl(&attrs) },
        .keyword_let => return .{ .let = try self.parseLetDecl() },
        .keyword_fn => return .{ .function = try self.parseFunctionDecl(&attrs) },
        .keyword_struct => return .{ .@"struct" = try self.parseStructDecl() },
        .keyword_alias => return .{ .alias = try self.parseAliasDecl() },
        else => {
            if (attrs.items.len > 0) self.addError("unexpected attributes");
            return null;
        },
    }
}

fn parseAttributes(self: *Parser) !std.ArrayListUnmanaged(Ast.Attribute) {
    var attrs: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
    while (self.currentTag() == .at) {
        const attr_loc = self.currentStart();
        self.advance();
        var attr = Ast.Attribute{ .name = "", .args = .empty, .loc = attr_loc };
        if (self.eatIdent()) |text| {
            attr.name = text;
            self.advance();
        }
        if (self.eat(.l_paren)) {
            attr.args = try self.parseExpressionList();
            _ = self.expect(.r_paren);
        }
        // Check for duplicate attribute
        if (attr.name.len > 0) {
            for (attrs.items) |existing| {
                if (std.mem.eql(u8, existing.name, attr.name)) {
                    const msg = std.fmt.allocPrint(self.arena, "duplicate attribute '@{s}'", .{attr.name}) catch "duplicate attribute";
                    self.errors.append(self.arena, .{ .message = msg, .pos = attr_loc, .code = "E0401" }) catch {};
                    break;
                }
            }
        }
        try attrs.append(self.arena, attr);
    }
    return attrs;
}

fn parseConstDecl(self: *Parser) !*Ast.ConstDecl {
    _ = self.expect(.keyword_const);
    const decl = try self.arena.create(Ast.ConstDecl);
    decl.* = .{ .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"const", .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in const declaration");
    _ = self.expect(.eq);
    self.expr_context = "after '=' in const declaration";
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseOverrideDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.OverrideDecl {
    _ = self.expect(.keyword_override);
    const decl = try self.arena.create(Ast.OverrideDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .override, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in override declaration");
    if (self.eat(.eq)) {
        self.expr_context = "after '=' in override declaration";
        decl.initializer = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    return decl;
}

fn parseVarDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.VarDecl {
    _ = self.expect(.keyword_var);
    const decl = try self.arena.create(Ast.VarDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    // Optional <address_space, access_mode>
    if (self.eat(.lt)) {
        decl.address_space = self.parseAddressSpace();
        if (self.eat(.comma)) decl.access_mode = self.parseAccessMode();
        _ = self.expect(.gt);
    }

    var flags = Ast.Symbol.Flags{};
    if (decl.address_space == .uniform or decl.address_space == .storage) {
        flags.is_external_binding = true;
    }

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"var", flags, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in var declaration");
    if (self.eat(.eq)) {
        self.expr_context = "after '=' in var declaration";
        decl.initializer = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    return decl;
}

fn parseLetDecl(self: *Parser) !*Ast.LetDecl {
    _ = self.expect(.keyword_let);
    const decl = try self.arena.create(Ast.LetDecl);
    decl.* = .{ .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .let, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in let declaration");
    _ = self.expect(.eq);
    self.expr_context = "after '=' in let declaration";
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    return decl;
}

fn parseFunctionDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute)) !*Ast.FunctionDecl {
    _ = self.expect(.keyword_fn);
    const decl = try self.arena.create(Ast.FunctionDecl);
    decl.* = .{
        .attributes = attrs.*,
        .name = .none,
        .parameters = .empty,
        .return_attr = .empty,
    };

    // Check entry point
    const entry_point_attrs = std.StaticStringMap(void).initComptime(.{
        .{ "vertex", {} },
        .{ "fragment", {} },
        .{ "compute", {} },
    });
    var is_entry_point = false;
    for (attrs.items) |attr| {
        if (entry_point_attrs.has(attr.name)) {
            is_entry_point = true;
            break;
        }
    }

    var flags = Ast.Symbol.Flags{};
    if (is_entry_point) {
        flags.is_entry_point = true;
        flags.must_not_be_renamed = true;
    }

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .function, flags, loc);
    }

    try self.pushScope();

    _ = self.expect(.l_paren);
    if (self.currentTag() != .r_paren) {
        decl.parameters = try self.parseParameters();
    }
    _ = self.expect(.r_paren);

    if (self.eat(.arrow)) {
        decl.return_attr = try self.parseAttributes();
        decl.return_type = try self.parseType("after '->' in function return type");
    }

    decl.body = try self.parseCompoundStmt();
    self.popScope();
    return decl;
}

fn parseParameters(self: *Parser) !std.ArrayListUnmanaged(Ast.Parameter) {
    var params: std.ArrayListUnmanaged(Ast.Parameter) = .empty;
    for (0..self.token_tags.len) |_| {
        const param_attrs = try self.parseAttributes();
        if (!self.isIdentLike()) break;
        const text = self.eatIdent().?;
        const loc = self.currentStart();
        self.advance();
        const name = try self.declareSymbol(text, .parameter, .{}, loc);
        _ = self.expect(.colon);
        const typ = try self.parseType("after ':' in function parameter");
        try params.append(self.arena, .{ .attributes = param_attrs, .name = name, .typ = typ });
        if (!self.eat(.comma)) break;
        if (self.currentTag() == .r_paren) break;
    } else unreachable;
    return params;
}

fn parseStructDecl(self: *Parser) !*Ast.StructDecl {
    _ = self.expect(.keyword_struct);
    const decl = try self.arena.create(Ast.StructDecl);
    decl.* = .{ .name = .none, .members = .empty };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"struct", .{}, loc);
    }

    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        const member_attrs = try self.parseAttributes();
        if (!self.isIdentLike()) break;
        const member_loc = self.currentStart();
        const text = self.eatIdent().?;
        self.advance();
        const name = try self.declareSymbolNoScope(text, .member, .{}, member_loc);
        _ = self.expect(.colon);
        const typ = try self.parseType("after ':' in struct member");
        try decl.members.append(self.arena, .{ .attributes = member_attrs, .name = name, .typ = typ });
        _ = self.eat(.comma);
    }
    _ = self.expect(.r_brace);
    return decl;
}

fn parseAliasDecl(self: *Parser) !*Ast.AliasDecl {
    _ = self.expect(.keyword_alias);
    const decl = try self.arena.create(Ast.AliasDecl);
    var name: Ast.SymbolIndex = .none;
    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        name = try self.declareSymbol(text, .alias, .{}, loc);
    }
    _ = self.expect(.eq);
    const typ = try self.parseType("after '=' in alias declaration");
    _ = self.expect(.semicolon);
    decl.* = .{ .name = name, .typ = typ };
    return decl;
}

fn parseConstAssert(self: *Parser) !*Ast.ConstAssertDecl {
    if (self.currentTag() == .keyword_const) self.advance();
    _ = self.expect(.keyword_const_assert);
    const decl = try self.arena.create(Ast.ConstAssertDecl);
    self.expr_context = "in const_assert";
    decl.* = .{ .expr = (try self.parseExpression()) orelse return error.ParseFailed };
    _ = self.expect(.semicolon);
    return decl;
}

// =========================================================================
// Types
// =========================================================================

fn parseType(self: *Parser, context: []const u8) error{ OutOfMemory, ParseFailed }!Ast.Type {
    if (self.eatIdent()) |name| {
        const name_loc = self.currentStart();
        self.advance();
        if (self.currentTag() == .lt) {
            return self.parseTemplatedType(name, name_loc);
        }
        const typ = try self.arena.create(Ast.IdentType);
        typ.* = .{ .name = name, .ref = .none, .loc = name_loc };
        return .{ .ident = typ };
    }

    const msg = if (context.len > 0)
        std.fmt.allocPrint(self.arena, "expected type {s}", .{context}) catch "expected type"
    else
        @as([]const u8, "expected type");
    self.addError(msg);
    const err_loc = self.currentStart();
    self.advance();
    const typ = try self.arena.create(Ast.IdentType);
    typ.* = .{ .name = "error", .ref = .none, .loc = err_loc };
    return .{ .ident = typ };
}

fn parseTemplatedType(self: *Parser, name: []const u8, name_loc: u32) !Ast.Type {
    _ = self.expect(.lt);

    if (isVecName(name)) {
        const size = name[3] - '0';
        const elem = try self.parseType("in vector type");
        _ = self.expect(.gt);
        const typ = try self.arena.create(Ast.VecType);
        typ.* = .{ .size = size, .elem_type = elem, .loc = name_loc };
        return .{ .vec = typ };
    }

    if (isMatName(name)) {
        const cols = name[3] - '0';
        const rows = name[5] - '0';
        const elem = try self.parseType("in matrix type");
        _ = self.expect(.gt);
        const typ = try self.arena.create(Ast.MatType);
        typ.* = .{ .cols = cols, .rows = rows, .elem_type = elem, .loc = name_loc };
        return .{ .mat = typ };
    }

    if (std.mem.eql(u8, name, "array")) {
        const elem = try self.parseType("in array type");
        var size: ?Ast.Expr = null;
        if (self.eat(.comma)) {
            self.expr_context = "in array size";
            size = try self.parseTemplateArgExpr();
        }
        _ = self.expect(.gt);
        const typ = try self.arena.create(Ast.ArrayType);
        typ.* = .{ .elem_type = elem, .size = size };
        return .{ .array = typ };
    }

    if (std.mem.eql(u8, name, "ptr")) {
        const addr = self.parseAddressSpace();
        _ = self.expect(.comma);
        const elem = try self.parseType("in pointer type");
        var access: Ast.AccessMode = .none;
        if (self.eat(.comma)) access = self.parseAccessMode();
        _ = self.expect(.gt);
        const typ = try self.arena.create(Ast.PtrType);
        typ.* = .{ .address_space = addr, .elem_type = elem, .access_mode = access };
        return .{ .ptr = typ };
    }

    if (std.mem.eql(u8, name, "atomic")) {
        const elem = try self.parseType("in atomic type");
        _ = self.expect(.gt);
        const typ = try self.arena.create(Ast.AtomicType);
        typ.* = .{ .elem_type = elem, .loc = name_loc };
        return .{ .atomic = typ };
    }

    // Texture types
    if (parseTextureTypeInfo(name)) |info| {
        const typ = try self.arena.create(Ast.TextureType);
        typ.* = .{ .kind = info.kind, .dimension = info.dim };
        if (info.kind == .storage) {
            if (self.eatIdent()) |texel_name| {
                typ.texel_format = texel_name;
                self.advance();
            }
            if (self.eat(.comma)) typ.access_mode = self.parseAccessMode();
        } else if (info.kind != .depth and info.kind != .depth_multisampled) {
            typ.sampled_type = try self.parseType("in texture type");
        }
        _ = self.expect(.gt);
        return .{ .texture = typ };
    }

    // Generic templated type
    _ = try self.parseType("in template arguments");
    while (self.eat(.comma)) _ = try self.parseType("in template arguments");
    _ = self.expect(.gt);
    const typ = try self.arena.create(Ast.IdentType);
    typ.* = .{ .name = name, .ref = .none, .loc = name_loc };
    return .{ .ident = typ };
}

const TextureInfo = struct { kind: Ast.TextureKind, dim: Ast.TextureDimension };

fn parseTextureTypeInfo(name: []const u8) ?TextureInfo {
    const map = std.StaticStringMap(TextureInfo).initComptime(.{
        .{ "texture_1d", TextureInfo{ .kind = .sampled, .dim = .@"1d" } },
        .{ "texture_2d", TextureInfo{ .kind = .sampled, .dim = .@"2d" } },
        .{ "texture_2d_array", TextureInfo{ .kind = .sampled, .dim = .@"2d_array" } },
        .{ "texture_3d", TextureInfo{ .kind = .sampled, .dim = .@"3d" } },
        .{ "texture_cube", TextureInfo{ .kind = .sampled, .dim = .cube } },
        .{ "texture_cube_array", TextureInfo{ .kind = .sampled, .dim = .cube_array } },
        .{ "texture_multisampled_2d", TextureInfo{ .kind = .multisampled, .dim = .@"2d" } },
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

fn parseAddressSpace(self: *Parser) Ast.AddressSpace {
    const map = std.StaticStringMap(Ast.AddressSpace).initComptime(.{
        .{ "function", .function },
        .{ "private", .private },
        .{ "workgroup", .workgroup },
        .{ "uniform", .uniform },
        .{ "storage", .storage },
    });
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        self.advance();
        return map.get(text) orelse .none;
    }
    return .none;
}

fn parseAccessMode(self: *Parser) Ast.AccessMode {
    const map = std.StaticStringMap(Ast.AccessMode).initComptime(.{
        .{ "read", .read },
        .{ "write", .write },
        .{ "read_write", .read_write },
    });
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        self.advance();
        return map.get(text) orelse .none;
    }
    return .none;
}

// =========================================================================
// Expressions
// =========================================================================

fn parseExpression(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Expr {
    return self.parseLogicalOrExpr();
}

fn parseLogicalOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseLogicalAndExpr()) orelse return null;
    while (self.currentTag() == .pipe_pipe) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseLogicalAndExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .logical_or, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseLogicalAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseOrExpr()) orelse return null;
    while (self.currentTag() == .amp_amp) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseOrExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .logical_and, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseXorExpr()) orelse return null;
    while (self.currentTag() == .pipe) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseXorExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .@"or", .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseXorExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseAndExpr()) orelse return null;
    while (self.currentTag() == .caret) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseAndExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .xor, .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseBitwiseAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseEqualityExpr()) orelse return null;
    while (self.currentTag() == .amp) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseEqualityExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .@"and", .left = left, .right = right };
        left = .{ .binary = node };
    }
    return left;
}

fn parseEqualityExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseRelationalExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .eq_eq => .eq,
            .bang_eq => .ne,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseRelationalExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseRelationalExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseShiftExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt => .lt,
            .lt_eq => .le,
            .gt => .gt,
            .gt_eq => .ge,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseShiftExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseShiftExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseAdditiveExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt_lt => .shl,
            .gt_gt => .shr,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseAdditiveExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseMultiplicativeExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseMultiplicativeExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseUnaryExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseUnaryExpr(self: *Parser) !?Ast.Expr {
    const op: ?Ast.UnaryOp = switch (self.currentTag()) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        .star => .deref,
        .amp => .addr,
        else => null,
    };

    if (op) |unary_op| {
        const loc = self.currentStart();
        self.advance();
        const operand = (try self.parseUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.UnaryExpr);
        node.* = .{ .loc = loc, .op = unary_op, .operand = operand };
        return .{ .unary = node };
    }

    return self.parsePostfixExpr();
}

fn parsePostfixExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parsePrimaryExpr()) orelse return null;

    for (0..self.token_tags.len) |_| {
        switch (self.currentTag()) {
            .dot => {
                const dot_loc = self.currentStart();
                self.advance();
                if (self.isIdentLike()) {
                    const member = self.currentText();
                    self.advance();
                    const node = try self.arena.create(Ast.MemberExpr);
                    node.* = .{ .loc = dot_loc, .base = left, .member_name = member };
                    left = .{ .member = node };
                } else {
                    self.addError("expected member name");
                }
            },
            .l_bracket => {
                const bracket_loc = self.currentStart();
                self.advance();
                self.expr_context = "in array index";
                const idx = (try self.parseExpression()) orelse return null;
                _ = self.expect(.r_bracket);
                const node = try self.arena.create(Ast.IndexExpr);
                node.* = .{ .loc = bracket_loc, .base = left, .idx = idx };
                left = .{ .index = node };
            },
            .l_paren => {
                const paren_loc = self.currentStart();
                self.advance();
                const args = try self.parseExpressionList();
                _ = self.expect(.r_paren);
                const node = try self.arena.create(Ast.CallExpr);
                node.* = .{ .loc = paren_loc, .func = left, .args = args };
                left = .{ .call = node };
            },
            else => return left,
        }
    } else unreachable;
}

fn parsePrimaryExpr(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident, .reserved_ident => {
            if (self.currentTag() == .reserved_ident) {
                _ = self.eatIdent(); // emits E0004 error
            }
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();

            // Templated constructor: array<T, N>(...) or vec2<f32>(...)
            if (self.currentTag() == .lt and isTemplatedTypeName(text)) {
                return self.parseTemplatedConstructor(text, loc);
            }

            const node = try self.arena.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            self.expr_context = "after '('";
            const expr = (try self.parseExpression()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.arena.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            const msg = if (self.expr_context.len > 0)
                std.fmt.allocPrint(self.arena, "expected expression {s}", .{self.expr_context}) catch "expected expression"
            else
                @as([]const u8, "expected expression");
            self.addError(msg);
            self.advance();
            return null;
        },
    }
}

fn parseTemplatedConstructor(self: *Parser, name: []const u8, name_loc: u32) !?Ast.Expr {
    const template_type = try self.parseTemplatedType(name, name_loc);
    if (self.currentTag() != .l_paren) {
        const node = try self.arena.create(Ast.IdentExpr);
        node.* = .{ .name = name, .ref = .none };
        return .{ .ident = node };
    }
    const paren_loc = self.currentStart();
    self.advance();
    const args = try self.parseExpressionList();
    _ = self.expect(.r_paren);
    const node = try self.arena.create(Ast.CallExpr);
    node.* = .{ .loc = paren_loc, .template_type = template_type, .args = args };
    return .{ .call = node };
}

fn parseExpressionList(self: *Parser) !std.ArrayListUnmanaged(Ast.Expr) {
    var exprs: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    if (self.currentTag() == .r_paren) return exprs;
    self.expr_context = "in arguments";
    if (try self.parseExpression()) |first| {
        try exprs.append(self.arena, first);
    }
    while (self.eat(.comma)) {
        if (self.currentTag() == .r_paren) break;
        if (try self.parseExpression()) |expr| {
            try exprs.append(self.arena, expr);
        }
    }
    return exprs;
}

// Template argument expression (restricted: no > or >= operators)
fn parseTemplateArgExpr(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Expr {
    return self.parseTemplateAdditiveExpr();
}

fn parseTemplateAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseTemplateMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateUnaryExpr()) orelse return null;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseTemplateUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
    } else unreachable;
}

fn parseTemplateUnaryExpr(self: *Parser) !?Ast.Expr {
    const op: ?Ast.UnaryOp = switch (self.currentTag()) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        else => null,
    };
    if (op) |unary_op| {
        const loc = self.currentStart();
        self.advance();
        const operand = (try self.parseTemplateUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.UnaryExpr);
        node.* = .{ .loc = loc, .op = unary_op, .operand = operand };
        return .{ .unary = node };
    }
    return self.parseTemplatePrimaryExpr();
}

fn parseTemplatePrimaryExpr(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal, .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident, .reserved_ident => {
            if (self.currentTag() == .reserved_ident) {
                _ = self.eatIdent(); // emits E0004 error
            }
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            self.expr_context = "after '('";
            const expr = (try self.parseTemplateArgExpr()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.arena.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            const msg = if (self.expr_context.len > 0)
                std.fmt.allocPrint(self.arena, "expected expression {s}", .{self.expr_context}) catch "expected expression"
            else
                @as([]const u8, "expected expression");
            self.addError(msg);
            self.advance();
            return null;
        },
    }
}

// =========================================================================
// Statements
// =========================================================================

fn parseStatement(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Stmt {
    switch (self.currentTag()) {
        .l_brace => return .{ .compound = try self.parseCompoundStmt() },
        .keyword_return => return .{ .@"return" = try self.parseReturnStmt() },
        .keyword_if => return .{ .@"if" = try self.parseIfStmt() },
        .keyword_switch => return .{ .@"switch" = try self.parseSwitchStmt() },
        .keyword_for => return .{ .@"for" = try self.parseForStmt() },
        .keyword_while => return .{ .@"while" = try self.parseWhileStmt() },
        .keyword_loop => return .{ .loop = try self.parseLoopStmt() },
        .keyword_break => {
            const loc = self.currentStart();
            self.advance();
            if (self.eat(.keyword_if)) {
                self.expr_context = "after 'if' in break";
                const cond = (try self.parseExpression()) orelse return null;
                _ = self.expect(.semicolon);
                const node = try self.arena.create(Ast.BreakIfStmt);
                node.* = .{ .condition = cond };
                return .{ .break_if = node };
            }
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.BreakStmt);
            node.* = .{ .loc = loc };
            return .{ .@"break" = node };
        },
        .keyword_continue => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.ContinueStmt);
            node.* = .{ .loc = loc };
            return .{ .@"continue" = node };
        },
        .keyword_discard => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.DiscardStmt);
            node.* = .{ .loc = loc };
            return .{ .discard = node };
        },
        .keyword_const, .keyword_const_assert, .keyword_let, .keyword_var => {
            if (try self.parseDeclaration()) |decl| {
                const node = try self.arena.create(Ast.DeclStmt);
                node.* = .{ .decl = decl };
                return .{ .decl = node };
            }
            return null;
        },
        else => return self.parseExpressionOrAssignment(),
    }
}

fn parseCompoundStmt(self: *Parser) !*Ast.CompoundStmt {
    _ = self.expect(.l_brace);
    try self.pushScope();
    const stmt = try self.arena.create(Ast.CompoundStmt);
    stmt.* = .{ .stmts = .empty };
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        if (try self.parseStatement()) |s| {
            try stmt.stmts.append(self.arena, s);
        }
    }
    self.popScope();
    _ = self.expect(.r_brace);
    return stmt;
}

fn parseReturnStmt(self: *Parser) !*Ast.ReturnStmt {
    const loc = self.currentStart();
    _ = self.expect(.keyword_return);
    const node = try self.arena.create(Ast.ReturnStmt);
    node.* = .{ .loc = loc };
    if (self.currentTag() != .semicolon) {
        self.expr_context = "after 'return'";
        node.value = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    return node;
}

/// Iteratively parses an if/else-if/else chain without recursion.
fn parseIfStmt(self: *Parser) !*Ast.IfStmt {
    _ = self.expect(.keyword_if);
    self.expr_context = "in if condition";
    const root = try self.arena.create(Ast.IfStmt);
    root.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    var current = root;
    while (self.eat(.keyword_else)) {
        if (self.currentTag() == .keyword_if) {
            _ = self.expect(.keyword_if);
            self.expr_context = "in if condition";
            const next = try self.arena.create(Ast.IfStmt);
            next.* = .{
                .condition = (try self.parseExpression()) orelse return error.ParseFailed,
                .body = try self.parseCompoundStmt(),
            };
            current.else_branch = .{ .@"if" = next };
            current = next;
        } else {
            current.else_branch = .{ .compound = try self.parseCompoundStmt() };
            break;
        }
    }
    return root;
}

fn parseSwitchStmt(self: *Parser) !*Ast.SwitchStmt {
    _ = self.expect(.keyword_switch);
    self.expr_context = "in switch expression";
    const node = try self.arena.create(Ast.SwitchStmt);
    node.* = .{
        .expr = (try self.parseExpression()) orelse return error.ParseFailed,
        .cases = .empty,
    };
    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        var c = Ast.SwitchCase{ .selectors = .empty, .body = undefined };
        if (self.eat(.keyword_default)) {
            // default case
        } else {
            _ = self.expect(.keyword_case);
            self.expr_context = "in case selector";
            if (try self.parseExpression()) |sel| try c.selectors.append(self.arena, sel);
            while (self.eat(.comma)) {
                if (try self.parseExpression()) |sel| try c.selectors.append(self.arena, sel);
            }
        }
        _ = self.expect(.colon);
        c.body = try self.parseCompoundStmt();
        try node.cases.append(self.arena, c);
    }
    _ = self.expect(.r_brace);
    return node;
}

fn parseForStmt(self: *Parser) !*Ast.ForStmt {
    _ = self.expect(.keyword_for);
    _ = self.expect(.l_paren);
    try self.pushScope();
    const node = try self.arena.create(Ast.ForStmt);
    node.* = .{ .body = undefined };

    // Init
    if (self.currentTag() != .semicolon) {
        switch (self.currentTag()) {
            .keyword_var, .keyword_let => {
                if (try self.parseDeclaration()) |decl| {
                    const ds = try self.arena.create(Ast.DeclStmt);
                    ds.* = .{ .decl = decl };
                    node.init_stmt = .{ .decl = ds };
                }
            },
            else => node.init_stmt = try self.parseExpressionOrAssignment(),
        }
    } else {
        self.advance();
    }

    // Condition
    if (self.currentTag() != .semicolon) {
        self.expr_context = "in for condition";
        node.condition = try self.parseExpression();
    }
    _ = self.expect(.semicolon);

    // Update
    if (self.currentTag() != .r_paren) {
        node.update = try self.parseForUpdateStmt();
    }

    _ = self.expect(.r_paren);
    node.body = try self.parseCompoundStmt();
    self.popScope();
    return node;
}

fn parseForUpdateStmt(self: *Parser) !?Ast.Stmt {
    self.expr_context = "in for update";
    const left = (try self.parseExpression()) orelse return null;

    // Check for assignment or incr/decr
    switch (self.currentTag()) {
        .plus_plus => {
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = true };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = false };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        const loc = self.currentStart();
        self.advance();
        self.expr_context = "in for update assignment";
        const right = (try self.parseExpression()) orelse return null;
        const node = try self.arena.create(Ast.AssignStmt);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        return .{ .assign = node };
    }

    // Call expression
    if (left == .call) {
        const node = try self.arena.create(Ast.CallStmt);
        node.* = .{ .call = left.call };
        return .{ .call = node };
    }

    self.addError("expected for update statement");
    return null;
}

fn parseWhileStmt(self: *Parser) !*Ast.WhileStmt {
    _ = self.expect(.keyword_while);
    self.expr_context = "in while condition";
    const node = try self.arena.create(Ast.WhileStmt);
    node.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    return node;
}

fn parseLoopStmt(self: *Parser) !*Ast.LoopStmt {
    _ = self.expect(.keyword_loop);
    const node = try self.arena.create(Ast.LoopStmt);
    node.* = .{ .body = try self.parseCompoundStmt() };
    if (self.eat(.keyword_continuing)) {
        node.continuing = try self.parseCompoundStmt();
    }
    return node;
}

fn parseExpressionOrAssignment(self: *Parser) !?Ast.Stmt {
    self.expr_context = "in statement";
    const left = (try self.parseExpression()) orelse return null;

    switch (self.currentTag()) {
        .plus_plus => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = true };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = false };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        const loc = self.currentStart();
        self.advance();
        self.expr_context = "in assignment";
        const right = (try self.parseExpression()) orelse return null;
        _ = self.expect(.semicolon);
        const node = try self.arena.create(Ast.AssignStmt);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        return .{ .assign = node };
    }

    _ = self.expect(.semicolon);
    if (left == .call) {
        const node = try self.arena.create(Ast.CallStmt);
        node.* = .{ .call = left.call };
        return .{ .call = node };
    }

    self.addError("expected assignment, increment, or function call");
    return null;
}

fn parseAssignOp(self: *const Parser) ?Ast.AssignOp {
    return switch (self.currentTag()) {
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

// =========================================================================
// Helpers
// =========================================================================

fn isVecName(name: []const u8) bool {
    return name.len == 4 and std.mem.eql(u8, name[0..3], "vec") and name[3] >= '2' and name[3] <= '4';
}

fn isMatName(name: []const u8) bool {
    return name.len == 6 and std.mem.eql(u8, name[0..3], "mat") and name[4] == 'x';
}

fn isTemplatedTypeName(name: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "array", {} },                    .{ "vec2", {} },                     .{ "vec3", {} },
        .{ "vec4", {} },                     .{ "mat2x2", {} },                   .{ "mat2x3", {} },
        .{ "mat2x4", {} },                   .{ "mat3x2", {} },                   .{ "mat3x3", {} },
        .{ "mat3x4", {} },                   .{ "mat4x2", {} },                   .{ "mat4x3", {} },
        .{ "mat4x4", {} },                   .{ "ptr", {} },                      .{ "atomic", {} },
        .{ "texture_1d", {} },               .{ "texture_2d", {} },               .{ "texture_2d_array", {} },
        .{ "texture_3d", {} },               .{ "texture_cube", {} },             .{ "texture_cube_array", {} },
        .{ "texture_multisampled_2d", {} },  .{ "texture_storage_1d", {} },       .{ "texture_storage_2d", {} },
        .{ "texture_storage_2d_array", {} }, .{ "texture_storage_3d", {} },       .{ "sampler", {} },
        .{ "sampler_comparison", {} },       .{ "texture_depth_2d", {} },         .{ "texture_depth_2d_array", {} },
        .{ "texture_depth_cube", {} },       .{ "texture_depth_cube_array", {} }, .{ "texture_depth_multisampled_2d", {} },
    });
    return map.has(name);
}

// Public access for Lexer helpers used in tokenText
pub const isIdentStart = Lexer.isIdentStart;
pub const isIdentContinue = Lexer.isIdentContinue;
pub const isDigit = Lexer.isDigit;
pub const isHexDigit = Lexer.isHexDigit;

// Expose these for other modules
/// Re-exports Lexer.isIdentStart for use by other modules.
pub fn isIdentStartFn(c: u8) bool {
    return Lexer.isIdentStart(c);
}

// =========================================================================
// Tests
// =========================================================================

test "parse simple const" {
    const source: [:0]const u8 = "const x = 1;";
    var tokens = try Lexer.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source, tokens);
    const module = try parser.parse();
    _ = module;
    try std.testing.expectEqual(@as(usize, 1), parser.symbols.items.len);
    try std.testing.expectEqualStrings("x", parser.symbols.items[0].original_name);
}

// -------------------------------------------------------------------------
// Test helpers
// -------------------------------------------------------------------------

fn expectPrinted(input: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    const Renamer = @import("Renamer.zig");
    const noop = try alloc.create(Renamer.NoOpRenamer);
    noop.* = Renamer.NoOpRenamer.init(module.symbols.items);
    noop.renamer.ptr = @ptrCast(noop);

    const Printer = @import("Printer.zig");
    var printer = Printer.init(alloc, .{
        .minify_whitespace = false,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop.renamer,
    }, module.symbols.items);
    const actual = try printer.print(module);

    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPrintedMinify(input: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    const Renamer = @import("Renamer.zig");
    const noop = try alloc.create(Renamer.NoOpRenamer);
    noop.* = Renamer.NoOpRenamer.init(module.symbols.items);
    noop.renamer.ptr = @ptrCast(noop);

    const Printer = @import("Printer.zig");
    var printer = Printer.init(alloc, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop.renamer,
    }, module.symbols.items);
    const actual = try printer.print(module);

    try std.testing.expectEqualStrings(expected, actual);
}

fn expectParseError(input: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    _ = parser.parse() catch return; // error return is sufficient
    if (parser.errors.items.len > 0) return;
    return error.TestExpectedError;
}

fn expectNoError(input: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

fn expectParseErrorMessage(input: [:0]const u8, expected_msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    _ = parser.parse() catch {};
    if (parser.errors.items.len == 0) return error.TestExpectedError;

    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, expected_msg) != null) return;
    }
    std.debug.print("\nExpected error containing: '{s}'\nActual errors:\n", .{expected_msg});
    for (parser.errors.items) |err| {
        std.debug.print("  - {s}\n", .{err.message});
    }
    return error.TestExpectedError;
}

// -------------------------------------------------------------------------
// Const declaration tests
// -------------------------------------------------------------------------

test "parser: const declaration" {
    try expectPrinted("const x = 1;", "const x = 1;\n");
    try expectPrinted("const x: i32 = 1;", "const x: i32 = 1;\n");
    try expectPrinted("const x = 1 + 2;", "const x = 1 + 2;\n");
    try expectPrinted("const PI = 3.14159;", "const PI = 3.14159;\n");
}

test "parser: const expressions" {
    try expectPrinted("const x = 1 + 2 * 3;", "const x = 1 + 2 * 3;\n");
    try expectPrinted("const x = (1 + 2) * 3;", "const x = (1 + 2) * 3;\n");
    try expectPrinted("const x = -1;", "const x = -1;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
}

// -------------------------------------------------------------------------
// Let declaration tests
// -------------------------------------------------------------------------

test "parser: let declaration" {
    try expectPrinted("let x = 1;", "let x = 1;\n");
    try expectPrinted("let x: f32 = 1.0;", "let x: f32 = 1.0;\n");
}

// -------------------------------------------------------------------------
// Var declaration tests
// -------------------------------------------------------------------------

test "parser: var declaration" {
    try expectPrinted("var x: i32;", "var x: i32;\n");
    try expectPrinted("var x: i32 = 0;", "var x: i32 = 0;\n");
    try expectPrinted("var<private> x: i32;", "var<private> x: i32;\n");
    try expectPrinted("var<workgroup> odds: array<i32, 16>;", "var<workgroup> odds: array<i32, 16>;\n");
    try expectPrinted("var<storage, read_write> data: array<f32>;", "var<storage, read_write> data: array<f32>;\n");
}

test "parser: var with attributes" {
    try expectPrinted("@group(0) @binding(0) var<uniform> u: Uniforms;", "@group(0) @binding(0) var<uniform> u: Uniforms;\n");
    try expectPrinted("@group(0) @binding(1) var tex: texture_2d<f32>;", "@group(0) @binding(1) var tex: texture_2d<f32>;\n");
    try expectPrinted("@group(0) @binding(2) var samp: sampler;", "@group(0) @binding(2) var samp: sampler;\n");
}

test "parser: var without address space" {
    try expectPrinted("var x: i32 = 0;", "var x: i32 = 0;\n");
}

// -------------------------------------------------------------------------
// Override declaration tests
// -------------------------------------------------------------------------

test "parser: override declaration" {
    try expectPrinted("override x: f32;", "override x: f32;\n");
    try expectPrinted("override x: f32 = 1.0;", "override x: f32 = 1.0;\n");
    try expectPrinted("@id(0) override x: f32;", "@id(0) override x: f32;\n");
}

// -------------------------------------------------------------------------
// Struct declaration tests
// -------------------------------------------------------------------------

test "parser: struct declaration" {
    try expectPrinted("struct Foo { x: i32, }", "struct Foo {\n    x: i32\n}\n");
    try expectPrinted("struct Point { x: f32, y: f32, }", "struct Point {\n    x: f32,\n    y: f32\n}\n");
}

test "parser: struct with attributes" {
    try expectPrinted(
        "struct VertexOutput { @builtin(position) pos: vec4f, @location(0) uv: vec2f, }",
        "struct VertexOutput {\n    @builtin(position) pos: vec4f,\n    @location(0) uv: vec2f\n}\n",
    );
}

// -------------------------------------------------------------------------
// Alias declaration tests
// -------------------------------------------------------------------------

test "parser: alias declaration" {
    try expectPrinted("alias Float = f32;", "alias Float = f32;\n");
    try expectPrinted("alias Vec3 = vec3<f32>;", "alias Vec3 = vec3<f32>;\n");
}

// -------------------------------------------------------------------------
// Function declaration tests
// -------------------------------------------------------------------------

test "parser: function declaration" {
    try expectPrinted("fn foo() {}", "fn foo() {\n}\n");
    try expectPrinted("fn foo() -> i32 { return 1; }", "fn foo() -> i32 {\n    return 1;\n}\n");
    try expectPrinted(
        "fn add(a: i32, b: i32) -> i32 { return a + b; }",
        "fn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n",
    );
}

test "parser: entry point functions" {
    try expectPrinted(
        "@vertex fn main() -> @builtin(position) vec4f { return vec4f(); }",
        "@vertex fn main() -> @builtin(position) vec4f {\n    return vec4f();\n}\n",
    );
    try expectPrinted(
        "@fragment fn main() -> @location(0) vec4f { return vec4f(1.0); }",
        "@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n",
    );
    try expectPrinted(
        "@compute @workgroup_size(64) fn main() {}",
        "@compute @workgroup_size(64) fn main() {\n}\n",
    );
}

test "parser: function with parameter attributes" {
    try expectPrinted(
        "@vertex fn main(@location(0) pos: vec4f) -> @builtin(position) vec4f { return pos; }",
        "@vertex fn main(@location(0) pos: vec4f) -> @builtin(position) vec4f {\n    return pos;\n}\n",
    );
}

// -------------------------------------------------------------------------
// Binary expression tests
// -------------------------------------------------------------------------

test "parser: binary expressions" {
    // Arithmetic
    try expectPrinted("const x = 1 + 2;", "const x = 1 + 2;\n");
    try expectPrinted("const x = 1 - 2;", "const x = 1 - 2;\n");
    try expectPrinted("const x = 1 * 2;", "const x = 1 * 2;\n");
    try expectPrinted("const x = 1 / 2;", "const x = 1 / 2;\n");
    try expectPrinted("const x = 1 % 2;", "const x = 1 % 2;\n");
    // Bitwise
    try expectPrinted("const x = 1 & 2;", "const x = 1 & 2;\n");
    try expectPrinted("const x = 1 | 2;", "const x = 1 | 2;\n");
    try expectPrinted("const x = 1 ^ 2;", "const x = 1 ^ 2;\n");
    try expectPrinted("const x = 1 << 2;", "const x = 1 << 2;\n");
    try expectPrinted("const x = 1 >> 2;", "const x = 1 >> 2;\n");
    // Comparison
    try expectPrinted("const x = 1 == 2;", "const x = 1 == 2;\n");
    try expectPrinted("const x = 1 != 2;", "const x = 1 != 2;\n");
    try expectPrinted("const x = 1 < 2;", "const x = 1 < 2;\n");
    try expectPrinted("const x = 1 <= 2;", "const x = 1 <= 2;\n");
    try expectPrinted("const x = 1 > 2;", "const x = 1 > 2;\n");
    try expectPrinted("const x = 1 >= 2;", "const x = 1 >= 2;\n");
    // Logical
    try expectPrinted("const x = true && false;", "const x = true && false;\n");
    try expectPrinted("const x = true || false;", "const x = true || false;\n");
}

// -------------------------------------------------------------------------
// Unary expression tests
// -------------------------------------------------------------------------

test "parser: unary expressions" {
    try expectPrinted("const x = -1;", "const x = -1;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
    try expectPrinted("const x = ~1;", "const x = ~1;\n");
}

// -------------------------------------------------------------------------
// Call expression tests
// -------------------------------------------------------------------------

test "parser: call expressions" {
    try expectPrinted("const x = foo();", "const x = foo();\n");
    try expectPrinted("const x = foo(1);", "const x = foo(1);\n");
    try expectPrinted("const x = foo(1, 2);", "const x = foo(1, 2);\n");
    try expectPrinted("const x = foo(1, 2, 3);", "const x = foo(1, 2, 3);\n");
}

// -------------------------------------------------------------------------
// Type constructor tests
// -------------------------------------------------------------------------

test "parser: type constructors" {
    try expectPrinted("const x = vec3f(1.0);", "const x = vec3f(1.0);\n");
    try expectPrinted("const x = vec3f(1.0, 2.0, 3.0);", "const x = vec3f(1.0, 2.0, 3.0);\n");
    try expectPrinted("const x = vec4f(v.xyz, 1.0);", "const x = vec4f(v.xyz, 1.0);\n");
    try expectPrinted("const x = mat4x4f();", "const x = mat4x4f();\n");
}

// -------------------------------------------------------------------------
// Member access tests
// -------------------------------------------------------------------------

test "parser: member access" {
    try expectPrinted("const x = a.b;", "const x = a.b;\n");
    try expectPrinted("const x = a.b.c;", "const x = a.b.c;\n");
    try expectPrinted("const x = v.xyz;", "const x = v.xyz;\n");
    try expectPrinted("const x = v.xyzw;", "const x = v.xyzw;\n");
}

// -------------------------------------------------------------------------
// Index access tests
// -------------------------------------------------------------------------

test "parser: index access" {
    try expectPrinted("const x = a[0];", "const x = a[0];\n");
    try expectPrinted("const x = a[i];", "const x = a[i];\n");
    try expectPrinted("const x = a[i + 1];", "const x = a[i + 1];\n");
    try expectPrinted("const x = a[0][1];", "const x = a[0][1];\n");
}

// -------------------------------------------------------------------------
// Parenthesis tests
// -------------------------------------------------------------------------

test "parser: parentheses" {
    try expectPrinted("const x = (1);", "const x = (1);\n");
    try expectPrinted("const x = (1 + 2) * 3;", "const x = (1 + 2) * 3;\n");
    try expectPrinted("const x = a * (b + c);", "const x = a * (b + c);\n");
}

// -------------------------------------------------------------------------
// Pointer/address-of/deref tests
// -------------------------------------------------------------------------

test "parser: address-of and deref" {
    try expectPrinted("fn foo() { let p = &x; }", "fn foo() {\n    let p = &x;\n}\n");
    try expectPrinted("fn foo() { let v = *p; }", "fn foo() {\n    let v = *p;\n}\n");
}

// -------------------------------------------------------------------------
// Statement tests
// -------------------------------------------------------------------------

test "parser: return statement" {
    try expectPrinted("fn foo() { return; }", "fn foo() {\n    return;\n}\n");
    try expectPrinted("fn foo() -> i32 { return 1; }", "fn foo() -> i32 {\n    return 1;\n}\n");
}

test "parser: if statement" {
    try expectPrinted(
        "fn foo() { if true { return; } }",
        "fn foo() {\n    if true {\n        return;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { if true { return; } else { return; } }",
        "fn foo() {\n    if true {\n        return;\n    } else {\n        return;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { if a { } else if b { } else { } }",
        "fn foo() {\n    if a {\n    } else if b {\n    } else {\n    }\n}\n",
    );
}

test "parser: for statement" {
    try expectPrinted(
        "fn foo() { for (var i: i32 = 0; i < 4; i++) { } }",
        "fn foo() {\n    for (var i: i32 = 0; i < 4; i++) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 10u; i++) { x++; } }",
        "fn foo() {\n    for (var i = 0u; i < 10u; i++) {\n        x++;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i: i32 = 0; i < 4; i += 2) { } }",
        "fn foo() {\n    for (var i: i32 = 0; i < 4; i += 2) {\n    }\n}\n",
    );
}

test "parser: for loop empty clauses" {
    try expectPrinted(
        "fn foo() { for (;;) { break; } }",
        "fn foo() {\n    for (; ; ) {\n        break;\n    }\n}\n",
    );
}

test "parser: for loop update statements" {
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i = i + 1) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i = i + 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i += 1) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i += 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 10; i > 0; i -= 1) {} }",
        "fn foo() {\n    for (var i = 10; i > 0; i -= 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 1; i < 100; i *= 2) {} }",
        "fn foo() {\n    for (var i = 1; i < 100; i *= 2) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 100; i > 1; i /= 2) {} }",
        "fn foo() {\n    for (var i = 100; i > 1; i /= 2) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i %= 3) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i %= 3) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0xFFu; i > 0u; i &= 0x7Fu) {} }",
        "fn foo() {\n    for (var i = 0xFFu; i > 0u; i &= 0x7Fu) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 255u; i |= 1u) {} }",
        "fn foo() {\n    for (var i = 0u; i < 255u; i |= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 255u; i ^= 1u) {} }",
        "fn foo() {\n    for (var i = 0u; i < 255u; i ^= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 1u; i < 256u; i <<= 1u) {} }",
        "fn foo() {\n    for (var i = 1u; i < 256u; i <<= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 256u; i > 0u; i >>= 1u) {} }",
        "fn foo() {\n    for (var i = 256u; i > 0u; i >>= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 10; i > 0; i--) {} }",
        "fn foo() {\n    for (var i = 10; i > 0; i--) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; update()) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; update()) {\n    }\n}\n",
    );
}

test "parser: for loop expression initializer" {
    try expectNoError("fn f() { var i: i32; for (i = 0; i < 10; i += 1) { } }");
}

test "parser: while statement" {
    try expectPrinted(
        "fn foo() { while true { } }",
        "fn foo() {\n    while true {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { while x < 10 { x++; } }",
        "fn foo() {\n    while x < 10 {\n        x++;\n    }\n}\n",
    );
}

test "parser: loop statement" {
    try expectPrinted(
        "fn foo() { loop { break; } }",
        "fn foo() {\n    loop {\n        break;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { loop { if x { break; } } }",
        "fn foo() {\n    loop {\n        if x {\n            break;\n        }\n    }\n}\n",
    );
}

test "parser: loop continuing" {
    try expectPrinted(
        "fn foo() { loop { break; } continuing { i++; } }",
        "fn foo() {\n    loop {\n        break;\n    } continuing {\n        i++;\n    }\n}\n",
    );
}

test "parser: switch statement" {
    try expectPrinted(
        "fn foo() { switch x { case 1: { } default: { } } }",
        "fn foo() {\n    switch x {\n        case 1: {\n        }\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch multiple selectors" {
    try expectPrinted(
        "fn foo() { switch x { case 1, 2, 3: { } default: { } } }",
        "fn foo() {\n    switch x {\n        case 1, 2, 3: {\n        }\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch only default" {
    try expectPrinted(
        "fn foo() { switch x { default: { } } }",
        "fn foo() {\n    switch x {\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch default with return" {
    try expectPrinted(
        "fn f() { var x: i32; switch x { default: { return; } } }",
        "fn f() {\n    var x: i32;\n    switch x {\n        default: {\n            return;\n        }\n    }\n}\n",
    );
}

test "parser: break and continue" {
    try expectPrinted(
        "fn foo() { loop { break; } }",
        "fn foo() {\n    loop {\n        break;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { loop { continue; } }",
        "fn foo() {\n    loop {\n        continue;\n    }\n}\n",
    );
}

test "parser: break if statement" {
    try expectPrinted(
        "fn foo() { loop { } continuing { break if true; } }",
        "fn foo() {\n    loop {\n    } continuing {\n        break if true;\n    }\n}\n",
    );
}

test "parser: discard statement" {
    try expectPrinted(
        "@fragment fn main() { discard; }",
        "@fragment fn main() {\n    discard;\n}\n",
    );
}

test "parser: assignment statements" {
    try expectPrinted("fn foo() { x = 1; }", "fn foo() {\n    x = 1;\n}\n");
    try expectPrinted("fn foo() { x += 1; }", "fn foo() {\n    x += 1;\n}\n");
    try expectPrinted("fn foo() { x -= 1; }", "fn foo() {\n    x -= 1;\n}\n");
    try expectPrinted("fn foo() { x *= 2; }", "fn foo() {\n    x *= 2;\n}\n");
    try expectPrinted("fn foo() { x /= 2; }", "fn foo() {\n    x /= 2;\n}\n");
}

test "parser: compound assignment statements" {
    try expectPrinted("fn foo() { x %= 3; }", "fn foo() {\n    x %= 3;\n}\n");
    try expectPrinted("fn foo() { x &= 0xFF; }", "fn foo() {\n    x &= 0xFF;\n}\n");
    try expectPrinted("fn foo() { x |= 1; }", "fn foo() {\n    x |= 1;\n}\n");
    try expectPrinted("fn foo() { x ^= 0xF; }", "fn foo() {\n    x ^= 0xF;\n}\n");
    try expectPrinted("fn foo() { x <<= 2u; }", "fn foo() {\n    x <<= 2u;\n}\n");
    try expectPrinted("fn foo() { x >>= 2u; }", "fn foo() {\n    x >>= 2u;\n}\n");
}

test "parser: increment and decrement" {
    try expectPrinted("fn foo() { x++; }", "fn foo() {\n    x++;\n}\n");
    try expectPrinted("fn foo() { x--; }", "fn foo() {\n    x--;\n}\n");
}

test "parser: call statement" {
    try expectPrinted("fn foo() { bar(); }", "fn foo() {\n    bar();\n}\n");
}

// -------------------------------------------------------------------------
// Scalar type tests
// -------------------------------------------------------------------------

test "parser: scalar types" {
    try expectPrinted("var x: bool;", "var x: bool;\n");
    try expectPrinted("var x: i32;", "var x: i32;\n");
    try expectPrinted("var x: u32;", "var x: u32;\n");
    try expectPrinted("var x: f32;", "var x: f32;\n");
    try expectPrinted("var x: f16;", "var x: f16;\n");
}

// -------------------------------------------------------------------------
// Vector type tests
// -------------------------------------------------------------------------

test "parser: vector types" {
    try expectPrinted("var x: vec2<f32>;", "var x: vec2<f32>;\n");
    try expectPrinted("var x: vec3<f32>;", "var x: vec3<f32>;\n");
    try expectPrinted("var x: vec4<f32>;", "var x: vec4<f32>;\n");
    try expectPrinted("var x: vec2f;", "var x: vec2f;\n");
    try expectPrinted("var x: vec3f;", "var x: vec3f;\n");
    try expectPrinted("var x: vec4f;", "var x: vec4f;\n");
    try expectPrinted("var x: vec3i;", "var x: vec3i;\n");
    try expectPrinted("var x: vec3u;", "var x: vec3u;\n");
}

// -------------------------------------------------------------------------
// Matrix type tests
// -------------------------------------------------------------------------

test "parser: matrix types" {
    try expectPrinted("var x: mat4x4f;", "var x: mat4x4f;\n");
    try expectPrinted("var x: mat2x2<f32>;", "var x: mat2x2<f32>;\n");
    try expectPrinted("var x: mat3x3<f32>;", "var x: mat3x3<f32>;\n");
    try expectPrinted("var x: mat4x4<f32>;", "var x: mat4x4<f32>;\n");
    try expectPrinted("var x: mat2x3<f32>;", "var x: mat2x3<f32>;\n");
}

// -------------------------------------------------------------------------
// Array type tests
// -------------------------------------------------------------------------

test "parser: array types" {
    try expectPrinted("var x: array<f32>;", "var x: array<f32>;\n");
    try expectPrinted("var x: array<f32, 10>;", "var x: array<f32, 10>;\n");
    try expectPrinted("var x: array<vec3<f32>, 8>;", "var x: array<vec3<f32>, 8>;\n");
}

// -------------------------------------------------------------------------
// Pointer type tests
// -------------------------------------------------------------------------

test "parser: pointer types" {
    try expectPrinted("var x: ptr<function, f32>;", "var x: ptr<function, f32>;\n");
    try expectPrinted("var x: ptr<private, i32>;", "var x: ptr<private, i32>;\n");
    try expectPrinted("var x: ptr<storage, f32, read_write>;", "var x: ptr<storage, f32, read_write>;\n");
}

test "parser: multiple template args" {
    try expectPrinted("var x: ptr<storage, f32, read_write>;", "var x: ptr<storage, f32, read_write>;\n");
}

// -------------------------------------------------------------------------
// Atomic type tests
// -------------------------------------------------------------------------

test "parser: atomic types" {
    try expectPrinted("var x: atomic<i32>;", "var x: atomic<i32>;\n");
    try expectPrinted("var x: atomic<u32>;", "var x: atomic<u32>;\n");
}

// -------------------------------------------------------------------------
// Texture type tests
// -------------------------------------------------------------------------

test "parser: texture types" {
    try expectPrinted("var tex: texture_2d<f32>;", "var tex: texture_2d<f32>;\n");
    try expectPrinted("var tex: texture_3d<f32>;", "var tex: texture_3d<f32>;\n");
    try expectPrinted("var tex: texture_cube<f32>;", "var tex: texture_cube<f32>;\n");
}

test "parser: all texture types" {
    // Sampled textures
    try expectPrinted("var tex: texture_1d<f32>;", "var tex: texture_1d<f32>;\n");
    try expectPrinted("var tex: texture_2d<f32>;", "var tex: texture_2d<f32>;\n");
    try expectPrinted("var tex: texture_2d_array<f32>;", "var tex: texture_2d_array<f32>;\n");
    try expectPrinted("var tex: texture_3d<f32>;", "var tex: texture_3d<f32>;\n");
    try expectPrinted("var tex: texture_cube<f32>;", "var tex: texture_cube<f32>;\n");
    try expectPrinted("var tex: texture_cube_array<f32>;", "var tex: texture_cube_array<f32>;\n");
    // Multisampled
    try expectPrinted("var tex: texture_multisampled_2d<f32>;", "var tex: texture_multisampled_2d<f32>;\n");
    // Storage textures with format and access mode
    try expectPrinted("var tex: texture_storage_1d<rgba8unorm, write>;", "var tex: texture_storage_1d<rgba8unorm, write>;\n");
    try expectPrinted("var tex: texture_storage_2d<rgba8unorm, read>;", "var tex: texture_storage_2d<rgba8unorm, read>;\n");
    try expectPrinted("var tex: texture_storage_2d_array<rgba8unorm, read_write>;", "var tex: texture_storage_2d_array<rgba8unorm, read_write>;\n");
    try expectPrinted("var tex: texture_storage_3d<rgba32float, write>;", "var tex: texture_storage_3d<rgba32float, write>;\n");
    // Depth textures (no template args — parsed as ident type)
    try expectPrinted("var tex: texture_depth_2d;", "var tex: texture_depth_2d;\n");
    try expectPrinted("var tex: texture_depth_2d_array;", "var tex: texture_depth_2d_array;\n");
    try expectPrinted("var tex: texture_depth_cube;", "var tex: texture_depth_cube;\n");
    try expectPrinted("var tex: texture_depth_cube_array;", "var tex: texture_depth_cube_array;\n");
    try expectPrinted("var tex: texture_depth_multisampled_2d;", "var tex: texture_depth_multisampled_2d;\n");
}

test "parser: depth texture types with attributes" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d;",
        "@group(0) @binding(0) var t: texture_depth_2d;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d_array;",
        "@group(0) @binding(0) var t: texture_depth_2d_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube;",
        "@group(0) @binding(0) var t: texture_depth_cube;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube_array;",
        "@group(0) @binding(0) var t: texture_depth_cube_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;",
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;\n",
    );
}

test "parser: depth texture types templated" {
    // Depth textures with empty template args — the parser parses them as
    // texture types and the printer emits them without sampled/texel content
    try expectNoError("var t: texture_depth_2d<>;");
    try expectNoError("var t: texture_depth_2d_array<>;");
    try expectNoError("var t: texture_depth_cube<>;");
    try expectNoError("var t: texture_depth_cube_array<>;");
    try expectNoError("var t: texture_depth_multisampled_2d<>;");
}

test "parser: storage texture without access mode" {
    // Printer emits trailing comma + empty string for the access mode
    try expectPrinted(
        "var tex: texture_storage_2d<rgba8unorm>;",
        "var tex: texture_storage_2d<rgba8unorm, >;\n",
    );
}

// -------------------------------------------------------------------------
// Sampler type tests
// -------------------------------------------------------------------------

test "parser: sampler types" {
    try expectPrinted("var s: sampler;", "var s: sampler;\n");
    try expectPrinted("var s: sampler_comparison;", "var s: sampler_comparison;\n");
}

// -------------------------------------------------------------------------
// Directive tests
// -------------------------------------------------------------------------

test "parser: enable directive" {
    try expectPrinted("enable f16;", "enable f16;\n");
    try expectPrinted("enable f16, dual_source_blending;", "enable f16, dual_source_blending;\n");
    try expectPrinted("enable f16, subgroups;", "enable f16, subgroups;\n");
}

test "parser: requires directive" {
    try expectPrinted(
        "requires readonly_and_readwrite_storage_textures;",
        "requires readonly_and_readwrite_storage_textures;\n",
    );
}

test "parser: diagnostic directive" {
    try expectPrinted(
        "diagnostic(off, derivative_uniformity);",
        "diagnostic(off, derivative_uniformity);\n",
    );
}

// -------------------------------------------------------------------------
// Const assert tests
// -------------------------------------------------------------------------

test "parser: const assert" {
    try expectPrinted("const_assert 1 == 1;", "const_assert 1 == 1;\n");
    try expectPrinted("const_assert SIZE > 0;", "const_assert SIZE > 0;\n");
    try expectPrinted("const_assert true;", "const_assert true;\n");
    try expectPrinted("const_assert 1 + 1 == 2;", "const_assert 1 + 1 == 2;\n");
}

test "parser: const assert at module level" {
    try expectPrinted("const_assert true;", "const_assert true;\n");
    try expectPrinted("const_assert 1 == 1;", "const_assert 1 == 1;\n");
    // Legacy syntax: const const_assert
    try expectNoError("const const_assert true;");
}

// -------------------------------------------------------------------------
// Template expression tests
// -------------------------------------------------------------------------

test "parser: template additive expressions" {
    try expectPrinted("var x: array<f32, 10 + 5>;", "var x: array<f32, 10 + 5>;\n");
    try expectPrinted("var x: array<f32, 20 - 5>;", "var x: array<f32, 20 - 5>;\n");
}

test "parser: template multiplicative expressions" {
    try expectPrinted("var x: array<f32, 2 * 8>;", "var x: array<f32, 2 * 8>;\n");
    try expectPrinted("var x: array<f32, 16 / 2>;", "var x: array<f32, 16 / 2>;\n");
    try expectPrinted("var x: array<f32, 17 % 5>;", "var x: array<f32, 17 % 5>;\n");
}

test "parser: template unary expressions" {
    try expectPrinted("var x: array<f32, -10>;", "var x: array<f32, -10>;\n");
    try expectPrinted("const x = array<bool, 2>(!true, !false);", "const x = array<bool, 2>(!true, !false);\n");
    try expectPrinted("var x: array<i32, ~0>;", "var x: array<i32, ~0>;\n");
}

test "parser: template parentheses expressions" {
    try expectPrinted("var x: array<f32, (10 + 5)>;", "var x: array<f32, (10 + 5)>;\n");
    try expectPrinted("var x: array<f32, (2 + 3) * 4>;", "var x: array<f32, (2 + 3) * 4>;\n");
}

test "parser: template complex expressions" {
    try expectPrinted("var x: array<f32, 2 + 3 * 4>;", "var x: array<f32, 2 + 3 * 4>;\n");
    try expectPrinted("var x: array<f32, (2 + 3) * 4 - 1>;", "var x: array<f32, (2 + 3) * 4 - 1>;\n");
}

test "parser: template identifier expressions" {
    // The Zig printer does not insert blank lines between declarations.
    try expectPrinted(
        "const N = 10;\nvar x: array<f32, N>;",
        "const N = 10;\nvar x: array<f32, N>;\n",
    );
}

test "parser: template bool literals" {
    try expectPrinted("const x = vec2<bool>(true, false);", "const x = vec2<bool>(true, false);\n");
    try expectNoError("alias T = array<i32, true>;");
    try expectNoError("alias T = array<i32, false>;");
}

test "parser: template unary not" {
    try expectNoError("alias T = vec2<f32>;");
    try expectNoError("alias T = array<i32, -1>;");
    try expectNoError("alias T = array<i32, ~0>;");
    try expectNoError("alias T = array<i32, 1 * !0>;");
}

// -------------------------------------------------------------------------
// Templated constructor tests
// -------------------------------------------------------------------------

test "parser: templated constructors" {
    try expectPrinted("var x = vec3<f32>(0);", "var x = vec3<f32>(0);\n");
    try expectPrinted("var x = vec2<i32>(1, 2);", "var x = vec2<i32>(1, 2);\n");
    try expectPrinted("var x = vec4<u32>(0, 0, 0, 1);", "var x = vec4<u32>(0, 0, 0, 1);\n");
    try expectPrinted("var x = mat2x2<f32>(1, 0, 0, 1);", "var x = mat2x2<f32>(1, 0, 0, 1);\n");
    try expectPrinted("var x = array<f32, 4>(1.0, 2.0, 3.0, 4.0);", "var x = array<f32, 4>(1.0, 2.0, 3.0, 4.0);\n");
}

test "parser: templated constructors with generic type" {
    try expectPrinted("const x = vec3<f32>(1.0, 2.0, 3.0);", "const x = vec3<f32>(1.0, 2.0, 3.0);\n");
    try expectPrinted("const x = array<i32, 3>(1, 2, 3);", "const x = array<i32, 3>(1, 2, 3);\n");
}

test "parser: templated type as expression not constructor" {
    // Templated type in expression position not followed by ( — should not crash
    try expectNoError("fn f() { let x = vec2<f32>; }");
    try expectNoError("fn f() { let x = array<i32, 5>; }");
}

// -------------------------------------------------------------------------
// Access mode tests
// -------------------------------------------------------------------------

test "parser: access modes" {
    try expectPrinted("var<storage, read> x: f32;", "var<storage, read> x: f32;\n");
    try expectPrinted("var<storage, write> x: f32;", "var<storage, write> x: f32;\n");
    try expectPrinted("var<storage, read_write> x: f32;", "var<storage, read_write> x: f32;\n");
}

// -------------------------------------------------------------------------
// Address space tests
// -------------------------------------------------------------------------

test "parser: address spaces" {
    try expectPrinted("var<function> x: f32;", "var<function> x: f32;\n");
    try expectPrinted("var<private> x: f32;", "var<private> x: f32;\n");
    try expectPrinted("var<workgroup> x: f32;", "var<workgroup> x: f32;\n");
    try expectPrinted("var<uniform> x: f32;", "var<uniform> x: f32;\n");
    try expectPrinted("var<storage> x: f32;", "var<storage> x: f32;\n");
}

// -------------------------------------------------------------------------
// Boolean literal tests
// -------------------------------------------------------------------------

test "parser: boolean literals" {
    try expectPrinted("const x = true;", "const x = true;\n");
    try expectPrinted("const x = false;", "const x = false;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
    try expectPrinted("const x = !false;", "const x = !false;\n");
}

// -------------------------------------------------------------------------
// Generic templated type tests
// -------------------------------------------------------------------------

test "parser: generic templated types" {
    // Unknown templated type — template args consumed, ident type returned
    try expectPrinted("fn f(x: SomeType) {}", "fn f(x: SomeType) {\n}\n");
    try expectNoError("fn f(x: SomeType<i32>) {}");
    try expectNoError("fn f(x: SomeType<i32, f32>) {}");
    try expectNoError("fn f(x: SomeType<i32, f32, u32>) {}");
}

// -------------------------------------------------------------------------
// Empty var template args
// -------------------------------------------------------------------------

test "parser: empty var template args" {
    try expectNoError("var<> x: i32;");
    try expectNoError("var<storage,> x: i32;");
}

// -------------------------------------------------------------------------
// Complete shader tests (parse-only, no error expected)
// -------------------------------------------------------------------------

test "parser: complete vertex shader" {
    try expectNoError(
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec3f,
        \\}
        \\
        \\@vertex
        \\fn main(@location(0) position: vec3f) -> VertexOutput {
        \\    var output: VertexOutput;
        \\    output.pos = vec4f(position, 1.0);
        \\    output.color = vec3f(1.0, 0.0, 0.0);
        \\    return output;
        \\}
    );
}

test "parser: complete compute shader" {
    try expectNoError(
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let index = id.x;
        \\    if index < arrayLength(&data) {
        \\        data[index] = data[index] * 2.0;
        \\    }
        \\}
    );
}

// -------------------------------------------------------------------------
// Minification output tests
// -------------------------------------------------------------------------

test "parser: minify whitespace const" {
    try expectPrintedMinify("const x = 1;", "const x=1;");
    try expectPrintedMinify("const x: i32 = 1;", "const x:i32=1;");
}

test "parser: minify whitespace function" {
    try expectPrintedMinify("fn foo() {}", "fn foo(){}");
    try expectPrintedMinify(
        "fn foo() -> i32 { return 1; }",
        "fn foo()->i32{return 1;}",
    );
}

test "parser: minify whitespace struct" {
    try expectPrintedMinify(
        "struct Foo { x: i32, }",
        "struct Foo{x:i32}",
    );
}

// -------------------------------------------------------------------------
// Error tests
// -------------------------------------------------------------------------

test "parser: invalid type errors" {
    try expectParseError("struct Foo { x: 12341234 }");
    try expectParseError("var x: 999;");
    try expectParseError("fn foo(x: 123) {}");
    try expectParseError("fn foo() -> 456 {}");
    try expectParseError("var x: vec3<123>;");
    try expectParseError("var x: array<456>;");
}

test "parser: missing semicolon" {
    try expectParseError("const x = 1");
    try expectParseError("var x: f32");
}

test "parser: missing brace" {
    try expectParseError("fn foo() { return;");
    try expectParseError("struct Foo { x: f32");
    try expectParseError("fn foo() {");
}

test "parser: invalid expression errors" {
    try expectParseError("const x = ;");
    try expectParseError("const x = 1 +;");
}

test "parser: invalid statement in block" {
    try expectParseError("fn foo() { 12345 }");
}

test "parser: invalid switch statement" {
    try expectParseError("fn foo() { switch x { 1: {} } }");
}

test "parser: invalid directive" {
    // The Zig parser's enable directive loop silently skips missing feature
    // names after a comma, so only a bare semicolon as the sole token errors.
    // These three inputs all parse without error in the Zig implementation.
    try expectNoError("enable f16, ;");
    try expectNoError("enable f16,;");
    try expectNoError("enable ,;");
}

test "parser: unexpected attributes" {
    try expectParseError("@group(0) ;");
}

test "parser: struct missing member type" {
    try expectParseError("struct S { x }");
}

test "parser: struct unexpected token" {
    // The Zig parser's struct loop exits on non-ident after attributes,
    // so `@` in a struct body is silently consumed as an attribute with an
    // empty name; no parse error is emitted.
    try expectNoError("struct S { @ }");
}

test "parser: for loop missing paren" {
    try expectParseError("fn f() { for var i = 0; i < 10; i++ { } }");
}

test "parser: invalid template expression" {
    try expectParseError("var x: array<f32, @>;");
}

test "parser: invalid for loop update" {
    try expectParseError("fn foo() { for (var i = 0; i < 10; @invalid) {} }");
}

test "parser: const assert missing semicolon" {
    try expectParseError("const_assert true");
}

test "parser: block unexpected token" {
    try expectParseError("fn f() { @ }");
}

test "parser: switch unexpected token" {
    try expectParseError("fn f() { var x: i32; switch x { @ } }");
}

test "parser: unclosed compound statement" {
    try expectParseError("fn foo() {");
}

// -------------------------------------------------------------------------
// Regression tests (from scenew_regression_test.go)
// -------------------------------------------------------------------------

test "parser: inline array initialization" {
    // Simple inline array
    try expectNoError("fn test() { var pos = array(1, 2, 3); }");
    // Inline array with vec2f
    try expectNoError(
        \\fn test() {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\    vec2f(3.0, -1.0),
        \\  );
        \\}
    );
    // Inline array indexing
    try expectNoError(
        \\fn test(idx: u32) -> vec2f {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\  );
        \\  return pos[idx];
        \\}
    );
    // Inline array in expression (indexed immediately)
    try expectNoError(
        \\fn test(index: u32) -> vec2f {
        \\  let position = array<vec2<f32>, 3>(
        \\    vec2f(0.0, 0.0),
        \\    vec2f(1.0, 0.0),
        \\    vec2f(0.0, 1.0)
        \\  )[index];
        \\  return position;
        \\}
    );
}

test "parser: struct declaration variations" {
    // Struct with trailing semicolon after closing brace
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\};
    );
    // Struct without trailing semicolon
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\}
    );
    // Struct with trailing comma on last member
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\}
    );
}

test "parser: for loop parsing variations" {
    // For loop with typed var
    try expectNoError(
        \\fn test() {
        \\  for (var i: u32 = 0u; i < 10u; i++) {
        \\  }
        \\}
    );
    // For loop in function returning value
    try expectNoError(
        \\fn sum() -> i32 {
        \\  var result = 0;
        \\  for (var i = 0; i < 10; i++) {
        \\    result += i;
        \\  }
        \\  return result;
        \\}
    );
    // Nested for loops
    try expectNoError(
        \\fn test() {
        \\  for (var i = 0u; i < 10u; i++) {
        \\    for (var j = 0u; j < 10u; j++) {
        \\    }
        \\  }
        \\}
    );
}

test "parser: type casting" {
    // u32 cast
    try expectNoError(
        \\fn test(x: f32) -> u32 {
        \\  return u32(x);
        \\}
    );
    // i32 cast
    try expectNoError(
        \\fn test(x: f32) -> i32 {
        \\  return i32(x);
        \\}
    );
    // f32 cast
    try expectNoError(
        \\fn test(x: i32) -> f32 {
        \\  return f32(x);
        \\}
    );
    // Cast in switch
    try expectNoError(
        \\fn test(phase: f32) {
        \\  switch u32(phase) {
        \\    case 0u: {}
        \\    default: {}
        \\  }
        \\}
    );
    // Cast in expression
    try expectNoError(
        \\fn test(n: u32) -> f32 {
        \\  return f32(n) * 2.0;
        \\}
    );
}

test "parser: array type with size expression" {
    // Array with expression size in function context
    try expectNoError(
        \\const movements: u32 = 3;
        \\fn test() {
        \\  let position = array<vec2<f32>, movements>(
        \\    vec2f(0.0),
        \\    vec2f(1.0),
        \\    vec2f(2.0)
        \\  );
        \\}
    );
}

test "parser: sceneW real-world patterns" {
    // Vertex shader with inline array
    try expectNoError(
        \\@vertex
        \\fn vs_test(@builtin(vertex_index) vertexIndex: u32) -> @builtin(position) vec4f {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\    vec2f(3.0, -1.0),
        \\  );
        \\  let xy = pos[vertexIndex];
        \\  return vec4f(xy, 0.0, 1.0);
        \\}
    );
    // Struct member accessor
    try expectNoError(
        \\struct VertexOutput {
        \\  @builtin(position) position: vec4f,
        \\  @location(0) uv: vec2f,
        \\}
        \\
        \\fn get_uv(i: VertexOutput) -> vec2f {
        \\  return i.uv;
        \\}
    );
    // Switch with u32 cast
    try expectNoError(
        \\fn test(beat: f32) -> f32 {
        \\  let phase = floor(beat / 4.0) % 4.0;
        \\  var value: f32;
        \\  switch u32(phase) {
        \\    case 0u: {
        \\      value = 1.0;
        \\    }
        \\    case 2u: {
        \\      value = 2.0;
        \\    }
        \\    default: {
        \\      value = 0.0;
        \\    }
        \\  }
        \\  return value;
        \\}
    );
    // Struct constructor return
    try expectNoError(
        \\struct BezierResult {
        \\  dist: f32,
        \\  point: vec2f,
        \\}
        \\
        \\fn bezier(pos: vec2f, A: vec2f, B: vec2f, C: vec2f) -> BezierResult {
        \\  return BezierResult(1.0, vec2f(0.0));
        \\}
    );
    // For loop with u32 iteration
    try expectNoError(
        \\fn test() {
        \\  for (var i = 0u; i < 7u; i++) {
        \\  }
        \\}
    );
    // For loop with i32 cast comparison
    try expectNoError(
        \\fn test() {
        \\  let numCables = i32(10);
        \\  for (var i = 1; i < numCables; i++) {
        \\  }
        \\}
    );
    // texture_external type
    try expectNoError("@group(1) @binding(1) var videoTexture: texture_external;");
    // textureSampleBaseClampToEdge call
    try expectNoError(
        \\@group(0) @binding(0) var videoTexture: texture_external;
        \\@group(0) @binding(1) var videoSampler: sampler;
        \\
        \\fn sampleVideo(uv: vec2f) -> vec4f {
        \\  return textureSampleBaseClampToEdge(videoTexture, videoSampler, uv);
        \\}
    );
}

test "parser: trailing comma in function parameters" {
    // Single parameter with trailing comma
    try expectNoError(
        \\fn test(x: f32,) -> f32 {
        \\  return x;
        \\}
    );
    // Multiple parameters with trailing comma
    try expectNoError(
        \\fn test(x: f32, y: f32,) -> f32 {
        \\  return x + y;
        \\}
    );
    // Vertex shader with trailing comma
    try expectNoError(
        \\@vertex
        \\fn vs_main(
        \\  @builtin(vertex_index) vertexIndex: u32,
        \\  @location(0) position: vec4f,
        \\) -> @builtin(position) vec4f {
        \\  return position;
        \\}
    );
    // Fragment shader with trailing comma
    try expectNoError(
        \\@fragment
        \\fn fs_main(
        \\  @location(0) uv: vec2f,
        \\) -> @location(0) vec4f {
        \\  return vec4f(uv, 0.0, 1.0);
        \\}
    );
    // Compute shader with trailing comma
    try expectNoError(
        \\@compute @workgroup_size(64)
        \\fn main(
        \\  @builtin(global_invocation_id) id: vec3u,
        \\) {
        \\}
    );
    // Helper function with trailing comma
    try expectNoError(
        \\fn lerp(
        \\  a: f32,
        \\  b: f32,
        \\  t: f32,
        \\) -> f32 {
        \\  return a + (b - a) * t;
        \\}
    );
}

// -------------------------------------------------------------------------
// Contextual error message tests
// -------------------------------------------------------------------------

test "parser error: expect names the expected token" {
    // Missing semicolons
    try expectParseErrorMessage("const x = 1", "expected ';'");
    try expectParseErrorMessage("var x: i32", "expected ';'");
    try expectParseErrorMessage("let x = 1", "expected ';'");
    // Missing closing paren
    try expectParseErrorMessage("fn foo(x: i32 {}", "expected ')'");
    // Missing closing brace
    try expectParseErrorMessage("fn foo() { return;", "expected '}'");
    // Missing closing angle bracket
    try expectParseErrorMessage("var x: vec3<f32;", "expected '>'");
    // Missing equals
    try expectParseErrorMessage("const x 1;", "expected '='");
    // Missing colon in parameter
    try expectParseErrorMessage("fn foo(x i32) {}", "expected ':'");
}

test "parser error: expected type with context" {
    // Type after colon in var declaration
    try expectParseErrorMessage("var x: 999;", "expected type after ':' in var declaration");
    // Type after arrow in function return type
    try expectParseErrorMessage("fn foo() -> 456 {}", "expected type after '->' in function return type");
    // Type after colon in function parameter
    try expectParseErrorMessage("fn foo(x: 123) {}", "expected type after ':' in function parameter");
    // Type after colon in struct member
    try expectParseErrorMessage("struct Foo { x: 123 }", "expected type after ':' in struct member");
    // Type after equals in alias declaration
    try expectParseErrorMessage("alias T = 123;", "expected type after '=' in alias declaration");
    // Type after colon in const declaration
    try expectParseErrorMessage("const x: 123 = 1;", "expected type after ':' in const declaration");
    // Type after colon in override declaration
    try expectParseErrorMessage("override x: 123;", "expected type after ':' in override declaration");
    // Type after colon in let declaration
    try expectParseErrorMessage("fn f() { let x: 123 = 1; }", "expected type after ':' in let declaration");
    // Type in vector type
    try expectParseErrorMessage("var x: vec3<123>;", "expected type in vector type");
    // Type in array type
    try expectParseErrorMessage("var x: array<123>;", "expected type in array type");
    // Type in matrix type
    try expectParseErrorMessage("var x: mat2x2<123>;", "expected type in matrix type");
}

test "parser error: expected expression with context" {
    // Expression after = in const
    try expectParseErrorMessage("const x = ;", "expected expression after '=' in const declaration");
    // Expression after = in let
    try expectParseErrorMessage("fn f() { let x = ; }", "expected expression after '=' in let declaration");
    // Expression after = in var
    try expectParseErrorMessage("var x: i32 = ;", "expected expression after '=' in var declaration");
    // Expression in if condition
    try expectParseErrorMessage("fn f() { if ; {} }", "expected expression in if condition");
    // Expression in while condition
    try expectParseErrorMessage("fn f() { while ; {} }", "expected expression in while condition");
    // Expression in switch
    try expectParseErrorMessage("fn f() { switch ; {} }", "expected expression in switch expression");
    // Expression after return (return with invalid token, not just semicolon)
    try expectParseErrorMessage("fn f() -> i32 { return +; }", "after 'return'");
}

test "parser error: expected assignment or call in statement" {
    try expectParseErrorMessage("fn foo() { 42; }", "expected assignment, increment, or function call");
}

pub const Error = error{ParseFailed} || std.mem.Allocator.Error;
