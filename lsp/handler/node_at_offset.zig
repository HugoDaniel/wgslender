//! AST node-at-position lookup. Walks declarations, statements, and
//! expressions to find the most specific node covering a byte offset
//! in the source. Used by Hover, Definition, References, Rename,
//! Document Highlight, Type Definition, and Call Hierarchy.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;

pub const NodeAtPosition = union(enum) {
    /// An identifier expression referencing a symbol.
    ident: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// A member access expression (e.g., `s.field`).
    member_access: struct { member: []const u8, loc: u32, base: Ast.Expr, ref: Ast.SymbolIndex },
    /// A declaration name (the identifier in fn/struct/var/const/let/alias).
    decl_name: struct { sym_idx: Ast.SymbolIndex, loc: u32 },
    /// A type reference (e.g., `f32`, `MyStruct` in a type annotation).
    type_ref: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// A binary operator expression (cursor on the operator token).
    binary_expr: struct { expr: Ast.Expr, loc: u32, op_len: u32 },
    /// No identifiable node at this position.
    none,
};

/// Find the AST node at a given byte offset in the source.
/// Walks declarations, statements, and expressions to find the
/// most specific node covering the offset.
pub fn find(module: *const Ast.Module, offset: u32) NodeAtPosition {
    for (module.declarations.items) |decl| {
        const result = findInDecl(module, decl, offset);
        if (result != .none) return result;
    }
    return .none;
}

/// Linear name lookup over module symbols. Used by `findInExpr` to resolve
/// idents whose `ref` is unbound — most notably attribute-arg idents, which
/// `AstVisit.visitDecl` deliberately skips (see `Incremental.zig:925-935`).
/// Mirrors the fallback already used by `resolveConstIntExprDepth`.
fn lookupSymbolByName(module: *const Ast.Module, name: []const u8) Ast.SymbolIndex {
    for (module.symbols.items, 0..) |sym, idx| {
        if (std.mem.eql(u8, sym.original_name, name)) {
            return @enumFromInt(@as(u32, @intCast(idx)));
        }
    }
    return .none;
}

/// Find the AST node at `offset` within a single declaration.
///
/// `find` walks every declaration; callers that already know which one
/// covers the offset (via `Ast.Decl.declSpan`) can skip straight to it.
/// `semantic_tokens.zig` does exactly that, because it resolves one node
/// per identifier token rather than one per request.
pub fn findInDeclaration(module: *const Ast.Module, decl: Ast.Decl, offset: u32) NodeAtPosition {
    return findInDecl(module, decl, offset);
}

fn findInDecl(module: *const Ast.Module, decl: Ast.Decl, offset: u32) NodeAtPosition {
    switch (decl) {
        .function => |f| {
            for (f.attributes.items) |attr| {
                for (attr.args.items) |arg| {
                    if (findInExpr(module, arg, offset)) |r| return r;
                }
            }
            if (checkDeclName(module, f.name, offset)) |r| return r;
            for (f.parameters.items) |param| {
                for (param.attributes.items) |attr| {
                    for (attr.args.items) |arg| {
                        if (findInExpr(module, arg, offset)) |r| return r;
                    }
                }
                if (checkDeclName(module, param.name, offset)) |r| return r;
                if (findInType(module, param.typ, offset)) |r| return r;
            }
            if (f.return_type) |rt| {
                if (findInType(module, rt, offset)) |r| return r;
            }
            for (f.return_attr.items) |attr| {
                for (attr.args.items) |arg| {
                    if (findInExpr(module, arg, offset)) |r| return r;
                }
            }
            if (f.body) |body| {
                if (findInCompound(module, body, offset)) |r| return r;
            }
        },
        .@"struct" => |s| {
            if (checkDeclName(module, s.name, offset)) |r| return r;
            for (s.members.items) |m| {
                for (m.attributes.items) |attr| {
                    for (attr.args.items) |arg| {
                        if (findInExpr(module, arg, offset)) |r| return r;
                    }
                }
                if (checkDeclName(module, m.name, offset)) |r| return r;
                if (findInType(module, m.typ, offset)) |r| return r;
            }
        },
        .@"const" => |c| {
            if (checkDeclName(module, c.name, offset)) |r| return r;
            if (c.typ) |t| {
                if (findInType(module, t, offset)) |r| return r;
            }
            if (c.initializer) |initializer| {
                if (findInExpr(module, initializer, offset)) |r| return r;
            }
        },
        .override => |o| {
            for (o.attributes.items) |attr| {
                for (attr.args.items) |arg| {
                    if (findInExpr(module, arg, offset)) |r| return r;
                }
            }
            if (checkDeclName(module, o.name, offset)) |r| return r;
            if (o.typ) |t| {
                if (findInType(module, t, offset)) |r| return r;
            }
            if (o.initializer) |initializer| {
                if (findInExpr(module, initializer, offset)) |r| return r;
            }
        },
        .@"var" => |v| {
            for (v.attributes.items) |attr| {
                for (attr.args.items) |arg| {
                    if (findInExpr(module, arg, offset)) |r| return r;
                }
            }
            if (checkDeclName(module, v.name, offset)) |r| return r;
            if (v.typ) |t| {
                if (findInType(module, t, offset)) |r| return r;
            }
            if (v.initializer) |initializer| {
                if (findInExpr(module, initializer, offset)) |r| return r;
            }
        },
        .let => |l| {
            if (checkDeclName(module, l.name, offset)) |r| return r;
            if (l.typ) |t| {
                if (findInType(module, t, offset)) |r| return r;
            }
            if (l.initializer) |initializer| {
                if (findInExpr(module, initializer, offset)) |r| return r;
            }
        },
        .alias => |a| {
            if (checkDeclName(module, a.name, offset)) |r| return r;
            if (findInType(module, a.typ, offset)) |r| return r;
        },
        .const_assert => |ca| {
            if (findInExpr(module, ca.expr, offset)) |r| return r;
        },
    }
    return .none;
}

fn checkDeclName(module: *const Ast.Module, sym_idx: Ast.SymbolIndex, offset: u32) ?NodeAtPosition {
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
        return .{ .decl_name = .{ .sym_idx = sym_idx, .loc = sym.loc } };
    }
    return null;
}

fn findInType(module: *const Ast.Module, typ: Ast.Type, offset: u32) ?NodeAtPosition {
    switch (typ) {
        .ident => |t| {
            if (offset >= t.loc and offset < t.loc + @as(u32, @intCast(t.name.len))) {
                return .{ .type_ref = .{ .name = t.name, .ref = t.ref, .loc = t.loc } };
            }
        },
        .vec => |t| {
            if (t.elem_type) |et| return findInType(module, et, offset);
        },
        .mat => |t| {
            if (t.elem_type) |et| return findInType(module, et, offset);
        },
        .array => |t| {
            if (t.elem_type) |et| {
                if (findInType(module, et, offset)) |r| return r;
            }
            if (t.size) |sz| {
                // size is an Expr, not a Type
                return findInExpr(module, sz, offset);
            }
        },
        .ptr => |t| return findInType(module, t.elem_type, offset),
        .atomic => |t| return findInType(module, t.elem_type, offset),
        .sampler, .texture => {},
    }
    return null;
}

fn findInCompound(module: *const Ast.Module, compound: *const Ast.CompoundStmt, offset: u32) ?NodeAtPosition {
    for (compound.stmts.items) |stmt| {
        if (findInStmt(module, stmt, offset)) |r| return r;
    }
    return null;
}

fn findInStmt(module: *const Ast.Module, stmt: Ast.Stmt, offset: u32) ?NodeAtPosition {
    switch (stmt) {
        .compound => |c| return findInCompound(module, c, offset),
        .@"return" => |r| {
            if (r.value) |v| return findInExpr(module, v, offset);
        },
        .@"if" => |i| {
            if (findInExpr(module, i.condition, offset)) |r| return r;
            if (findInCompound(module, i.body, offset)) |r| return r;
            if (i.else_branch) |eb| return findInStmt(module, eb, offset);
        },
        .@"switch" => |s| {
            if (findInExpr(module, s.expr, offset)) |r| return r;
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| {
                    if (findInExpr(module, sel, offset)) |r| return r;
                }
                if (findInCompound(module, case.body, offset)) |r| return r;
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| {
                if (findInStmt(module, init_s, offset)) |r| return r;
            }
            if (f.condition) |cond| {
                if (findInExpr(module, cond, offset)) |r| return r;
            }
            if (f.update) |upd| {
                if (findInStmt(module, upd, offset)) |r| return r;
            }
            return findInCompound(module, f.body, offset);
        },
        .@"while" => |w| {
            if (findInExpr(module, w.condition, offset)) |r| return r;
            return findInCompound(module, w.body, offset);
        },
        .loop => |l| {
            if (findInCompound(module, l.body, offset)) |r| return r;
            if (l.continuing) |cont| return findInCompound(module, cont, offset);
        },
        .assign => |a| {
            if (findInExpr(module, a.left, offset)) |r| return r;
            return findInExpr(module, a.right, offset);
        },
        .incr_decr => |i| return findInExpr(module, i.expr, offset),
        .call => |c| return findInExpr(module, .{ .call = c.call }, offset),
        .decl => |d| {
            const result = findInDecl(module, d.decl, offset);
            if (result != .none) return result;
        },
        .@"break" => {},
        .@"continue" => {},
        .discard => {},
        .break_if => |b| return findInExpr(module, b.condition, offset),
    }
    return null;
}

fn findInExpr(module: *const Ast.Module, expr: Ast.Expr, offset: u32) ?NodeAtPosition {
    switch (expr) {
        .ident => |e| {
            if (offset >= e.loc and offset < e.loc + @as(u32, @intCast(e.name.len))) {
                const ref = if (e.ref.isValid()) e.ref else lookupSymbolByName(module, e.name);
                return .{ .ident = .{ .name = e.name, .ref = ref, .loc = e.loc } };
            }
        },
        .member => |e| {
            // e.loc is the dot position; member name starts at dot + 1
            const member_loc = e.loc + 1;
            if (offset >= member_loc and offset < member_loc + @as(u32, @intCast(e.member_name.len))) {
                return .{ .member_access = .{ .member = e.member_name, .loc = member_loc, .base = e.base, .ref = e.member_ref } };
            }
            return findInExpr(module, e.base, offset);
        },
        .call => |e| {
            if (e.func) |f| {
                if (findInExpr(module, f, offset)) |r| return r;
            }
            if (e.template_type) |tt| {
                if (findInType(module, tt, offset)) |r| return r;
            }
            for (e.args.items) |arg| {
                if (findInExpr(module, arg, offset)) |r| return r;
            }
        },
        .binary => |e| {
            if (findInExpr(module, e.left, offset)) |r| return r;
            // Check if cursor is on the operator token itself
            const op_str = e.op.string();
            const op_len: u32 = @intCast(op_str.len);
            if (offset >= e.loc and offset < e.loc + op_len) {
                return .{ .binary_expr = .{ .expr = expr, .loc = e.loc, .op_len = op_len } };
            }
            return findInExpr(module, e.right, offset);
        },
        .unary => |e| return findInExpr(module, e.operand, offset),
        .index => |e| {
            if (findInExpr(module, e.base, offset)) |r| return r;
            return findInExpr(module, e.idx, offset);
        },
        .paren => |e| return findInExpr(module, e.expr, offset),
        .literal => {},
    }
    return null;
}
