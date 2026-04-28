//! Source edits built from an analyzed WGSL module.
//!
//! Byte-offset based, transport-independent. The LSP handler wraps these
//! functions and maps offsets to LSP Ranges; other callers (WASM, CLI,
//! build tools) can use them directly against the raw source string.
//!
//! Design: all writes target the ORIGINAL source text. Applying a
//! TextEdit list to the source preserves comments, formatting, and any
//! other trivia the parser discards. A caller who wants to modify a
//! shader gets edits, applies them to the source string, and re-runs
//! `analyze()` — no AST round-trip through the printer, no lost trivia.
//!
//! Invariants:
//!   - Every `TextEdit` has `start <= end` and both offsets index into the
//!     original `module.source`. Callers must apply edits in reverse byte
//!     order (last edit first) to keep offsets valid.
//!   - A returned `TextEdit` list is non-overlapping. Producers that build
//!     multi-edit operations (rename, change-type) verify this before
//!     returning so the apply order doesn't depend on edit-list order
//!     beyond reversal.
//!   - Edits are owned by the caller's allocator; the module/AST is read
//!     only and not mutated by any function in this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");

// =========================================================================
// Public types
// =========================================================================

/// A reference to a symbol at a specific byte range in the source.
pub const Reference = struct {
    /// Byte offset where the reference begins in the source.
    start: u32,
    /// Byte offset one past the last byte of the reference.
    end: u32,
    /// True if the reference appears on the LHS of an assignment or is
    /// the target of an in-place update (`x = y`, `x += 1`, `x++`).
    is_write: bool,
};

/// A text edit against the original source. Apply by replacing the
/// bytes in `[start, end)` with `new_text`.
pub const TextEdit = struct {
    start: u32,
    end: u32,
    new_text: []const u8,
};

// =========================================================================
// Identifier validity
// =========================================================================

/// Returns true if `name` is a valid WGSL identifier: non-empty, no `__`
/// prefix (reserved by the spec), not a keyword or reserved word, and
/// composed of `[A-Za-z_][A-Za-z0-9_]*`.
pub fn isValidWgslIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len >= 2 and name[0] == '_' and name[1] == '_') return false;
    if (Lexer.keywords_map.has(name)) return false;
    if (Lexer.reserved_words.has(name)) return false;
    for (name, 0..) |c, i| {
        if (i == 0) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
        } else {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }
    return true;
}

// =========================================================================
// Symbol lookup at byte offset
// =========================================================================

/// Returns the symbol whose declared name or reference covers `offset`,
/// or `.none` if the offset does not fall inside a symbol's identifier
/// token. Walks the module in declaration order.
///
/// Matches:
///   - identifier expressions (reads, writes)
///   - type references (`MyStruct` in type positions)
///   - top-level declaration names (`fn foo`, `struct S`, `var x`, ...)
///   - function parameter declaration names
///   - names of declarations nested inside function bodies (let/const/var)
///
/// Does not match struct member declaration names — member-access sites
/// carry a string, not a SymbolIndex, so renaming struct fields is not
/// a safe operation with the current AST.
pub fn symbolAtOffset(module: *Ast.Module, offset: u32) Ast.SymbolIndex {
    // Drain any deferred incremental bias so the ident/expr-level `.loc`
    // reads inside `SymbolFinder` see current coordinates.
    module.absorbInteriors();
    var v = SymbolFinder{ .module = module, .offset = offset };
    return v.findInModule();
}

const SymbolFinder = struct {
    module: *const Ast.Module,
    offset: u32,

    fn checkName(self: *const SymbolFinder, sym_ref: Ast.SymbolIndex) ?Ast.SymbolIndex {
        if (!sym_ref.isValid()) return null;
        const idx = sym_ref.index();
        if (idx >= self.module.symbols.items.len) return null;
        const sym = self.module.symbols.items[idx];
        const start = sym.loc;
        const end = start + @as(u32, @intCast(sym.original_name.len));
        if (self.offset >= start and self.offset < end) return sym_ref;
        return null;
    }

    fn findInModule(self: *const SymbolFinder) Ast.SymbolIndex {
        for (self.module.declarations.items) |decl| {
            if (self.findInDecl(decl)) |s| return s;
        }
        return .none;
    }

    fn findInDecl(self: *const SymbolFinder, decl: Ast.Decl) ?Ast.SymbolIndex {
        if (self.checkName(decl.nameRef())) |s| return s;
        switch (decl) {
            .function => |f| {
                for (f.parameters.items) |param| {
                    if (self.checkName(param.name)) |s| return s;
                    if (self.findInType(param.typ)) |s| return s;
                }
                if (f.return_type) |rt| if (self.findInType(rt)) |s| return s;
                if (f.body) |body| if (self.findInCompound(body)) |s| return s;
            },
            .@"struct" => |st| {
                // Intentionally skip member names — see doc comment above.
                for (st.members.items) |m| if (self.findInType(m.typ)) |s| return s;
            },
            .@"const" => |c| {
                if (c.typ) |t| if (self.findInType(t)) |s| return s;
                if (c.initializer) |e| if (self.findInExpr(e)) |s| return s;
            },
            .override => |o| {
                if (o.typ) |t| if (self.findInType(t)) |s| return s;
                if (o.initializer) |e| if (self.findInExpr(e)) |s| return s;
            },
            .@"var" => |v| {
                if (v.typ) |t| if (self.findInType(t)) |s| return s;
                if (v.initializer) |e| if (self.findInExpr(e)) |s| return s;
            },
            .let => |l| {
                if (l.typ) |t| if (self.findInType(t)) |s| return s;
                if (l.initializer) |e| if (self.findInExpr(e)) |s| return s;
            },
            .alias => |a| if (self.findInType(a.typ)) |s| return s,
            .const_assert => |ca| if (self.findInExpr(ca.expr)) |s| return s,
        }
        return null;
    }

    fn findInType(self: *const SymbolFinder, typ: Ast.Type) ?Ast.SymbolIndex {
        switch (typ) {
            .ident => |t| {
                const end = t.loc + @as(u32, @intCast(t.name.len));
                if (self.offset >= t.loc and self.offset < end and t.ref.isValid()) return t.ref;
            },
            .vec => |t| if (t.elem_type) |et| return self.findInType(et),
            .mat => |t| if (t.elem_type) |et| return self.findInType(et),
            .array => |t| {
                if (t.elem_type) |et| if (self.findInType(et)) |s| return s;
                if (t.size) |sz| if (self.findInExpr(sz)) |s| return s;
            },
            .ptr => |t| return self.findInType(t.elem_type),
            .atomic => |t| return self.findInType(t.elem_type),
            .sampler, .texture => {},
        }
        return null;
    }

    fn findInCompound(self: *const SymbolFinder, compound: *const Ast.CompoundStmt) ?Ast.SymbolIndex {
        for (compound.stmts.items) |stmt| if (self.findInStmt(stmt)) |s| return s;
        return null;
    }

    fn findInStmt(self: *const SymbolFinder, stmt: Ast.Stmt) ?Ast.SymbolIndex {
        switch (stmt) {
            .compound => |c| return self.findInCompound(c),
            .@"return" => |r| if (r.value) |v| return self.findInExpr(v),
            .@"if" => |i| {
                if (self.findInExpr(i.condition)) |s| return s;
                if (self.findInCompound(i.body)) |s| return s;
                if (i.else_branch) |eb| return self.findInStmt(eb);
            },
            .@"switch" => |sw| {
                if (self.findInExpr(sw.expr)) |s| return s;
                for (sw.cases.items) |case| {
                    for (case.selectors.items) |sel| if (self.findInExpr(sel)) |s| return s;
                    if (self.findInCompound(case.body)) |s| return s;
                }
            },
            .@"for" => |f| {
                if (f.init_stmt) |is| if (self.findInStmt(is)) |s| return s;
                if (f.condition) |c| if (self.findInExpr(c)) |s| return s;
                if (f.update) |u| if (self.findInStmt(u)) |s| return s;
                if (self.findInCompound(f.body)) |s| return s;
            },
            .@"while" => |w| {
                if (self.findInExpr(w.condition)) |s| return s;
                if (self.findInCompound(w.body)) |s| return s;
            },
            .loop => |l| {
                if (self.findInCompound(l.body)) |s| return s;
                if (l.continuing) |cont| if (self.findInCompound(cont)) |s| return s;
            },
            .assign => |a| {
                if (self.findInExpr(a.left)) |s| return s;
                if (self.findInExpr(a.right)) |s| return s;
            },
            .incr_decr => |i| return self.findInExpr(i.expr),
            .call => |c| return self.findInExpr(.{ .call = c.call }),
            .decl => |d| return self.findInDecl(d.decl),
            .break_if => |b| return self.findInExpr(b.condition),
            .@"break", .@"continue", .discard => {},
        }
        return null;
    }

    fn findInExpr(self: *const SymbolFinder, expr: Ast.Expr) ?Ast.SymbolIndex {
        switch (expr) {
            .ident => |e| {
                const end = e.loc + @as(u32, @intCast(e.name.len));
                if (self.offset >= e.loc and self.offset < end and e.ref.isValid()) return e.ref;
            },
            .member => |e| return self.findInExpr(e.base),
            .call => |e| {
                if (e.func) |f| if (self.findInExpr(f)) |s| return s;
                if (e.template_type) |tt| if (self.findInType(tt)) |s| return s;
                for (e.args.items) |arg| if (self.findInExpr(arg)) |s| return s;
            },
            .binary => |e| {
                if (self.findInExpr(e.left)) |s| return s;
                if (self.findInExpr(e.right)) |s| return s;
            },
            .unary => |e| return self.findInExpr(e.operand),
            .index => |e| {
                if (self.findInExpr(e.base)) |s| return s;
                if (self.findInExpr(e.idx)) |s| return s;
            },
            .paren => |e| return self.findInExpr(e.expr),
            .literal => {},
        }
        return null;
    }
};

// =========================================================================
// Reference collection
// =========================================================================

/// Returns every byte range in the source that references `target`.
/// If `include_declaration` is true, the declaration site is included
/// (as `is_write = true`). Caller owns the slice — free with `gpa.free`.
pub fn findReferences(
    gpa: Allocator,
    module: *Ast.Module,
    target: Ast.SymbolIndex,
    include_declaration: bool,
) Allocator.Error![]Reference {
    module.absorbInteriors();
    var refs: std.ArrayListUnmanaged(Reference) = .empty;
    defer refs.deinit(gpa);

    if (!target.isValid()) return try gpa.dupe(Reference, refs.items);

    if (include_declaration) {
        const sym = module.symbols.items[target.index()];
        try refs.append(gpa, .{
            .start = sym.loc,
            .end = sym.loc + @as(u32, @intCast(sym.original_name.len)),
            .is_write = true,
        });
    }

    for (module.declarations.items) |decl| {
        try collectInDecl(gpa, decl, target, &refs, false);
    }

    return try gpa.dupe(Reference, refs.items);
}

fn collectInDecl(
    gpa: Allocator,
    decl: Ast.Decl,
    target: Ast.SymbolIndex,
    refs: *std.ArrayListUnmanaged(Reference),
    is_write: bool,
) Allocator.Error!void {
    switch (decl) {
        .function => |f| {
            for (f.parameters.items) |param| try collectInType(gpa, param.typ, target, refs);
            if (f.return_type) |rt| try collectInType(gpa, rt, target, refs);
            if (f.body) |body| try collectInCompound(gpa, body, target, refs);
        },
        .@"struct" => |s| {
            for (s.members.items) |m| try collectInType(gpa, m.typ, target, refs);
        },
        .@"const" => |c| {
            if (c.typ) |t| try collectInType(gpa, t, target, refs);
            if (c.initializer) |e| try collectInExpr(gpa, e, target, refs, is_write);
        },
        .override => |o| {
            if (o.typ) |t| try collectInType(gpa, t, target, refs);
            if (o.initializer) |e| try collectInExpr(gpa, e, target, refs, is_write);
        },
        .@"var" => |v| {
            if (v.typ) |t| try collectInType(gpa, t, target, refs);
            if (v.initializer) |e| try collectInExpr(gpa, e, target, refs, is_write);
        },
        .let => |l| {
            if (l.typ) |t| try collectInType(gpa, t, target, refs);
            if (l.initializer) |e| try collectInExpr(gpa, e, target, refs, is_write);
        },
        .alias => |a| try collectInType(gpa, a.typ, target, refs),
        .const_assert => |ca| try collectInExpr(gpa, ca.expr, target, refs, false),
    }
}

fn collectInType(
    gpa: Allocator,
    typ: Ast.Type,
    target: Ast.SymbolIndex,
    refs: *std.ArrayListUnmanaged(Reference),
) Allocator.Error!void {
    switch (typ) {
        .ident => |t| {
            if (t.ref == target) {
                try refs.append(gpa, .{
                    .start = t.loc,
                    .end = t.loc + @as(u32, @intCast(t.name.len)),
                    .is_write = false,
                });
            }
        },
        .vec => |t| if (t.elem_type) |et| try collectInType(gpa, et, target, refs),
        .mat => |t| if (t.elem_type) |et| try collectInType(gpa, et, target, refs),
        .array => |t| {
            if (t.elem_type) |et| try collectInType(gpa, et, target, refs);
            if (t.size) |sz| try collectInExpr(gpa, sz, target, refs, false);
        },
        .ptr => |t| try collectInType(gpa, t.elem_type, target, refs),
        .atomic => |t| try collectInType(gpa, t.elem_type, target, refs),
        .sampler, .texture => {},
    }
}

fn collectInCompound(
    gpa: Allocator,
    compound: *const Ast.CompoundStmt,
    target: Ast.SymbolIndex,
    refs: *std.ArrayListUnmanaged(Reference),
) Allocator.Error!void {
    for (compound.stmts.items) |stmt| try collectInStmt(gpa, stmt, target, refs);
}

fn collectInStmt(
    gpa: Allocator,
    stmt: Ast.Stmt,
    target: Ast.SymbolIndex,
    refs: *std.ArrayListUnmanaged(Reference),
) Allocator.Error!void {
    switch (stmt) {
        .compound => |c| try collectInCompound(gpa, c, target, refs),
        .@"return" => |r| if (r.value) |v| try collectInExpr(gpa, v, target, refs, false),
        .@"if" => |i| {
            try collectInExpr(gpa, i.condition, target, refs, false);
            try collectInCompound(gpa, i.body, target, refs);
            if (i.else_branch) |eb| try collectInStmt(gpa, eb, target, refs);
        },
        .@"switch" => |s| {
            try collectInExpr(gpa, s.expr, target, refs, false);
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| try collectInExpr(gpa, sel, target, refs, false);
                try collectInCompound(gpa, case.body, target, refs);
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| try collectInStmt(gpa, init_s, target, refs);
            if (f.condition) |cond| try collectInExpr(gpa, cond, target, refs, false);
            if (f.update) |upd| try collectInStmt(gpa, upd, target, refs);
            try collectInCompound(gpa, f.body, target, refs);
        },
        .@"while" => |w| {
            try collectInExpr(gpa, w.condition, target, refs, false);
            try collectInCompound(gpa, w.body, target, refs);
        },
        .loop => |l| {
            try collectInCompound(gpa, l.body, target, refs);
            if (l.continuing) |cont| try collectInCompound(gpa, cont, target, refs);
        },
        .assign => |a| {
            try collectInExpr(gpa, a.left, target, refs, true);
            try collectInExpr(gpa, a.right, target, refs, false);
        },
        .incr_decr => |i| try collectInExpr(gpa, i.expr, target, refs, true),
        .call => |c| try collectInExpr(gpa, .{ .call = c.call }, target, refs, false),
        .decl => |d| try collectInDecl(gpa, d.decl, target, refs, false),
        .@"break", .@"continue", .discard => {},
        .break_if => |b| try collectInExpr(gpa, b.condition, target, refs, false),
    }
}

fn collectInExpr(
    gpa: Allocator,
    expr: Ast.Expr,
    target: Ast.SymbolIndex,
    refs: *std.ArrayListUnmanaged(Reference),
    is_write: bool,
) Allocator.Error!void {
    switch (expr) {
        .ident => |e| {
            if (e.ref == target) {
                try refs.append(gpa, .{
                    .start = e.loc,
                    .end = e.loc + @as(u32, @intCast(e.name.len)),
                    .is_write = is_write,
                });
            }
        },
        .member => |e| try collectInExpr(gpa, e.base, target, refs, is_write),
        .call => |e| {
            if (e.func) |f| try collectInExpr(gpa, f, target, refs, false);
            if (e.template_type) |tt| try collectInType(gpa, tt, target, refs);
            for (e.args.items) |arg| try collectInExpr(gpa, arg, target, refs, false);
        },
        .binary => |e| {
            try collectInExpr(gpa, e.left, target, refs, false);
            try collectInExpr(gpa, e.right, target, refs, false);
        },
        .unary => |e| try collectInExpr(gpa, e.operand, target, refs, false),
        .index => |e| {
            try collectInExpr(gpa, e.base, target, refs, is_write);
            try collectInExpr(gpa, e.idx, target, refs, false);
        },
        .paren => |e| try collectInExpr(gpa, e.expr, target, refs, is_write),
        .literal => {},
    }
}

// =========================================================================
// Rename
// =========================================================================

/// Produce the text edits that rename `target` to `new_name` at every
/// reference (including the declaration). Returns null if `new_name`
/// is not a valid WGSL identifier. Caller owns the returned slice and
/// is responsible for freeing with `gpa.free`.
///
/// The edits are sorted by ascending start offset so they can be applied
/// from last to first without offset-shift bookkeeping.
pub fn renameEdits(
    gpa: Allocator,
    module: *Ast.Module,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) Allocator.Error!?[]TextEdit {
    if (!isValidWgslIdentifier(new_name)) return null;
    if (!target.isValid()) return null;

    // `findReferences` absorbs any deferred bias for us.
    const refs = try findReferences(gpa, module, target, true);
    defer gpa.free(refs);

    const edits = try gpa.alloc(TextEdit, refs.len);
    for (refs, 0..) |r, i| {
        edits[i] = .{ .start = r.start, .end = r.end, .new_text = new_name };
    }
    std.mem.sort(TextEdit, edits, {}, struct {
        fn lessThan(_: void, a: TextEdit, b: TextEdit) bool {
            return a.start < b.start;
        }
    }.lessThan);
    return edits;
}

// =========================================================================
// Declaration-level edits
// =========================================================================

/// Describes where a symbol is declared in the module. Used by both
/// `removeDeclarationEdit` and `changeTypeEdit` to locate the syntactic
/// node whose span is to be edited.
pub const DeclSite = union(enum) {
    /// Module-scope declaration (or a local let/var/const statement whose
    /// symbol happens to be module-scope — the same walker reaches both).
    decl: Ast.Decl,
    /// A local declaration statement inside a function body.
    local_decl: Ast.Decl,
    /// A function parameter.
    parameter: *const Ast.Parameter,
    /// A struct member (not a `Decl` — owned by a `StructDecl`).
    member: *const Ast.StructMember,
    /// The target symbol is a function whose `return_type` we want to
    /// edit. `decl` is the owning function.
    return_type: *const Ast.FunctionDecl,
    /// Not found.
    none,
};

/// Locate the declaration site of a symbol. Walks module declarations
/// and their children. O(module size) per call; acceptable for
/// interactive edit flows. If `want_return_type` is true and `target`
/// is a function symbol with a return type, returns
/// `DeclSite{ .return_type = fn }`; otherwise returns the function decl
/// itself (used by `removeDeclarationEdit`).
pub fn findOwningDecl(
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
    want_return_type: bool,
) DeclSite {
    if (!target.isValid()) return .none;

    for (module.declarations.items) |decl| {
        // Whole-decl match on its own name.
        if (decl.nameRef() == target) {
            if (want_return_type) {
                // Caller wants the return type; only functions have one.
                if (decl == .function and decl.function.return_type != null) {
                    return .{ .return_type = decl.function };
                }
                // No return type to edit; fall through.
            }
            return .{ .decl = decl };
        }

        switch (decl) {
            .function => |f| {
                for (f.parameters.items) |*p| {
                    if (p.name == target) return .{ .parameter = p };
                }
                if (f.body) |body| {
                    if (findInCompound(body, target)) |site| return site;
                }
            },
            .@"struct" => |st| {
                for (st.members.items) |*m| {
                    if (m.name == target) return .{ .member = m };
                }
            },
            else => {},
        }
    }
    return .none;
}

fn findInCompound(compound: *const Ast.CompoundStmt, target: Ast.SymbolIndex) ?DeclSite {
    for (compound.stmts.items) |stmt| if (findInStmt(stmt, target)) |s| return s;
    return null;
}

fn findInStmt(stmt: Ast.Stmt, target: Ast.SymbolIndex) ?DeclSite {
    switch (stmt) {
        .compound => |c| return findInCompound(c, target),
        .@"if" => |i| {
            if (findInCompound(i.body, target)) |s| return s;
            if (i.else_branch) |eb| return findInStmt(eb, target);
        },
        .@"switch" => |sw| for (sw.cases.items) |case| {
            if (findInCompound(case.body, target)) |s| return s;
        },
        .@"for" => |f| {
            if (f.init_stmt) |is| if (findInStmt(is, target)) |s| return s;
            if (findInCompound(f.body, target)) |s| return s;
        },
        .@"while" => |w| if (findInCompound(w.body, target)) |s| return s,
        .loop => |l| {
            if (findInCompound(l.body, target)) |s| return s;
            if (l.continuing) |cont| if (findInCompound(cont, target)) |s| return s;
        },
        .decl => |d| {
            if (d.decl.nameRef() == target) return .{ .local_decl = d.decl };
        },
        else => {},
    }
    return null;
}

/// Produce a single `TextEdit` that deletes the full syntactic span of
/// the declaration owning `target`. Returns null if:
///   - `target` is `.none` or not a declaration name
///   - the symbol is a builtin (no source)
///   - the symbol is a struct member or parameter (remove_field /
///     remove_parameter would need punctuation-aware fixups — out of
///     scope here)
///   - the declaration has no captured span (parse-error recovery)
pub fn removeDeclarationEdit(
    gpa: Allocator,
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
) Allocator.Error!?[]TextEdit {
    const site = findOwningDecl(module, target, false);
    const span: Ast.Span = switch (site) {
        .decl, .local_decl => |d| d.declSpan(),
        // Members and parameters are not removable as whole-declarations.
        .member, .parameter, .return_type, .none => return null,
    };
    if (span.isEmpty()) return null;

    const edits = try gpa.alloc(TextEdit, 1);
    edits[0] = .{ .start = span.start, .end = span.end, .new_text = "" };
    return edits;
}

/// Cheap guard against obviously-malformed replacement text. Full type-
/// syntax validation is the caller's job (re-analyze the rewritten source).
fn isPlausibleTypeText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c == '\n' or c == '\r' or c == ';' or c == '}' or c == '{') return false;
    }
    return true;
}

/// Produce a single `TextEdit` that replaces the type annotation of
/// `target` with `new_type_text`. Works for any declaration site with a
/// type annotation:
///   - struct members and fn parameters (always typed)
///   - `var` / `const` / `override` / `let` with explicit `: T`
///   - function return type (pass the function's SymbolIndex)
///
/// Returns null for:
///   - `target` that is not addressable (none, builtin)
///   - decls without a type annotation (`typ == null`)
///   - malformed `new_type_text` (empty, multiline, or containing `;`/`{`/`}`)
///
/// The returned slice's element references `new_type_text` by slice; the
/// caller's buffer must outlive the edits (consistent with `renameEdits`).
pub fn changeTypeEdit(
    gpa: Allocator,
    module: *Ast.Module,
    target: Ast.SymbolIndex,
    new_type_text: []const u8,
) Allocator.Error!?[]TextEdit {
    if (!target.isValid()) return null;
    if (!isPlausibleTypeText(new_type_text)) return null;

    // Type spans live inside decl interiors — drain any deferred
    // incremental bias before reading `typ.span()` below.
    module.absorbInteriors();

    // For functions, `changeTypeEdit` targets the return type.
    const site = findOwningDecl(module, target, true);
    const typ_opt: ?Ast.Type = switch (site) {
        .decl, .local_decl => |d| switch (d) {
            .@"const" => |c| c.typ,
            .override => |o| o.typ,
            .@"var" => |v| v.typ,
            .let => |l| l.typ,
            .alias => |a| a.typ,
            .function, .@"struct", .const_assert => null,
        },
        .parameter => |p| p.typ,
        .member => |m| m.typ,
        .return_type => |f| f.return_type,
        .none => return null,
    };
    const typ = typ_opt orelse return null;
    const span = typ.span();
    if (span.isEmpty()) return null;

    const edits = try gpa.alloc(TextEdit, 1);
    edits[0] = .{ .start = span.start, .end = span.end, .new_text = new_type_text };
    return edits;
}

// =========================================================================
// Edit builders
// =========================================================================

/// Build a text edit that inserts `text` at `offset` without deleting
/// anything. Useful for "append after last binding" / "prepend" flows.
pub fn insertAt(offset: u32, text: []const u8) TextEdit {
    return .{ .start = offset, .end = offset, .new_text = text };
}

/// Build an edit that replaces the argument list of the `@workgroup_size`
/// attribute on the entry point named `entry_point_name` with `xyz`.
/// Returns null if no such entry point exists, or if the entry point has
/// no `@workgroup_size` attribute, or if the attribute's argument list
/// cannot be located in source (malformed input).
///
/// `xyz` is formatted as the minimal textual form:
///   [4, 1, 1] → "4"         (trailing 1s collapsed)
///   [8, 8, 1] → "8, 8"
///   [4, 4, 4] → "4, 4, 4"
pub fn setWorkgroupSize(
    gpa: Allocator,
    source: []const u8,
    module: *Ast.Module,
    entry_point_name: []const u8,
    xyz: [3]u32,
) Allocator.Error!?[]TextEdit {
    // `attr.loc` is an interior field — absorb before reading.
    module.absorbInteriors();
    for (module.declarations.items) |decl| {
        const f = switch (decl) {
            .function => |fn_decl| fn_decl,
            else => continue,
        };
        if (!f.name.isValid()) continue;
        const sym = module.symbols.items[f.name.index()];
        if (!std.mem.eql(u8, sym.original_name, entry_point_name)) continue;

        for (f.attributes.items) |attr| {
            if (!std.mem.eql(u8, attr.name, "workgroup_size")) continue;
            const arg_span = findAttrArgSpan(source, attr.loc) orelse return null;

            const args_text = try formatWorkgroupSizeArgs(gpa, xyz);
            const edits = try gpa.alloc(TextEdit, 1);
            edits[0] = .{ .start = arg_span.start, .end = arg_span.end, .new_text = args_text };
            return edits;
        }
        // Function found but no @workgroup_size attribute.
        return null;
    }
    return null;
}

/// Free a TextEdit slice previously returned by `setWorkgroupSize`. The
/// builder allocates the `new_text` strings from `gpa`, so callers must
/// free both the slice and each element's text.
pub fn freeBuiltEdits(gpa: Allocator, edits: []TextEdit) void {
    for (edits) |e| gpa.free(e.new_text);
    gpa.free(edits);
}

const AttrSpan = struct { start: u32, end: u32 };

/// Given the start offset of an `@name` attribute, return the span of
/// the argument list (contents between `(` and `)`, exclusive of both).
/// Returns null if no `(` follows the attribute name or the parens are
/// unbalanced.
fn findAttrArgSpan(source: []const u8, attr_loc: u32) ?AttrSpan {
    // attr_loc points at `@`. Scan forward to `(`.
    var i: usize = attr_loc;
    if (i >= source.len or source[i] != '@') return null;
    while (i < source.len and source[i] != '(') : (i += 1) {}
    if (i >= source.len) return null;
    const args_start: u32 = @intCast(i + 1);

    // Match parens, skipping nested ones.
    var depth: u32 = 1;
    i = args_start;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return .{ .start = args_start, .end = @intCast(i) };
            },
            else => {},
        }
    }
    return null;
}

fn formatWorkgroupSizeArgs(gpa: Allocator, xyz: [3]u32) Allocator.Error![]const u8 {
    // Collapse trailing 1s: [x,1,1]→"x", [x,y,1]→"x, y", else "x, y, z".
    const keep: usize = if (xyz[2] != 1) 3 else if (xyz[1] != 1) 2 else 1;
    return switch (keep) {
        1 => try std.fmt.allocPrint(gpa, "{d}", .{xyz[0]}),
        2 => try std.fmt.allocPrint(gpa, "{d}, {d}", .{ xyz[0], xyz[1] }),
        else => try std.fmt.allocPrint(gpa, "{d}, {d}, {d}", .{ xyz[0], xyz[1], xyz[2] }),
    };
}

// =========================================================================
// Apply edits
// =========================================================================

/// Apply a list of text edits to `source` and return the resulting
/// string (arena-allocated). Edits must not overlap. Any order is
/// accepted; the function sorts a copy internally. Caller-owned.
pub fn applyEdits(
    gpa: Allocator,
    source: []const u8,
    edits: []const TextEdit,
) Allocator.Error![]u8 {
    if (edits.len == 0) return try gpa.dupe(u8, source);

    // Sort a local copy ascending by start.
    const sorted = try gpa.alloc(TextEdit, edits.len);
    defer gpa.free(sorted);
    @memcpy(sorted, edits);
    std.mem.sort(TextEdit, sorted, {}, struct {
        fn lessThan(_: void, a: TextEdit, b: TextEdit) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // Compute output size.
    var out_len: usize = source.len;
    for (sorted) |e| {
        const span = e.end - e.start;
        out_len = out_len - span + e.new_text.len;
    }

    var out = try gpa.alloc(u8, out_len);
    var src_i: usize = 0;
    var dst_i: usize = 0;
    for (sorted) |e| {
        const start: usize = e.start;
        const end: usize = e.end;
        // Copy the untouched prefix.
        const prefix_len = start - src_i;
        @memcpy(out[dst_i .. dst_i + prefix_len], source[src_i..start]);
        dst_i += prefix_len;
        // Insert the replacement.
        @memcpy(out[dst_i .. dst_i + e.new_text.len], e.new_text);
        dst_i += e.new_text.len;
        src_i = end;
    }
    // Trailing suffix.
    @memcpy(out[dst_i..out_len], source[src_i..]);
    return out;
}

// =========================================================================
// Tests
// =========================================================================

test "isValidWgslIdentifier: basic accept" {
    try std.testing.expect(isValidWgslIdentifier("foo"));
    try std.testing.expect(isValidWgslIdentifier("_foo"));
    try std.testing.expect(isValidWgslIdentifier("foo123"));
}

test "isValidWgslIdentifier: rejects reserved and double underscore" {
    try std.testing.expect(!isValidWgslIdentifier(""));
    try std.testing.expect(!isValidWgslIdentifier("__reserved"));
    try std.testing.expect(!isValidWgslIdentifier("fn"));
    try std.testing.expect(!isValidWgslIdentifier("1leading"));
}

test "applyEdits: empty edits returns copy" {
    const src = "hello world";
    const out = try applyEdits(std.testing.allocator, src, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "applyEdits: single replace" {
    const src = "hello world";
    const edits = [_]TextEdit{.{ .start = 6, .end = 11, .new_text = "there" }};
    const out = try applyEdits(std.testing.allocator, src, &edits);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello there", out);
}

test "applyEdits: multiple replaces out of order" {
    const src = "one two three";
    const edits = [_]TextEdit{
        .{ .start = 8, .end = 13, .new_text = "THREE" },
        .{ .start = 0, .end = 3, .new_text = "ONE" },
        .{ .start = 4, .end = 7, .new_text = "TWO" },
    };
    const out = try applyEdits(std.testing.allocator, src, &edits);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ONE TWO THREE", out);
}

test "applyEdits: insertion (zero-length range)" {
    const src = "ab";
    const edits = [_]TextEdit{.{ .start = 1, .end = 1, .new_text = "XYZ" }};
    const out = try applyEdits(std.testing.allocator, src, &edits);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("aXYZb", out);
}

test "applyEdits: deletion (empty new_text)" {
    const src = "abcdef";
    const edits = [_]TextEdit{.{ .start = 2, .end = 4, .new_text = "" }};
    const out = try applyEdits(std.testing.allocator, src, &edits);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abef", out);
}

test "insertAt: produces zero-length range edit" {
    const e = insertAt(5, "hi");
    try std.testing.expectEqual(@as(u32, 5), e.start);
    try std.testing.expectEqual(@as(u32, 5), e.end);
    try std.testing.expectEqualStrings("hi", e.new_text);
}

test "findAttrArgSpan: simple" {
    const src = "@workgroup_size(8, 8, 1)";
    const span = findAttrArgSpan(src, 0).?;
    try std.testing.expectEqualStrings("8, 8, 1", src[span.start..span.end]);
}

test "findAttrArgSpan: nested parens" {
    const src = "@location(max(0, 1))";
    const span = findAttrArgSpan(src, 0).?;
    try std.testing.expectEqualStrings("max(0, 1)", src[span.start..span.end]);
}

test "findAttrArgSpan: missing paren returns null" {
    try std.testing.expect(findAttrArgSpan("@compute", 0) == null);
}

test "findAttrArgSpan: unclosed returns null" {
    try std.testing.expect(findAttrArgSpan("@wg(1, 2", 0) == null);
}

test "formatWorkgroupSizeArgs: collapses trailing 1s" {
    const a = std.testing.allocator;

    const one = try formatWorkgroupSizeArgs(a, .{ 4, 1, 1 });
    defer a.free(one);
    try std.testing.expectEqualStrings("4", one);

    const two = try formatWorkgroupSizeArgs(a, .{ 8, 8, 1 });
    defer a.free(two);
    try std.testing.expectEqualStrings("8, 8", two);

    const three = try formatWorkgroupSizeArgs(a, .{ 4, 4, 4 });
    defer a.free(three);
    try std.testing.expectEqualStrings("4, 4, 4", three);
}
