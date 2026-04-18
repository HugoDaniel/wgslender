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
///   - declaration names (`fn foo`, `struct S`, `var x`, etc.)
///
/// Does not match member names (struct field access) — members aren't
/// renameable as first-class symbols.
pub fn symbolAtOffset(module: *const Ast.Module, offset: u32) Ast.SymbolIndex {
    // Declaration names come first because they can bound wider spans.
    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (name_ref.isValid()) {
            const sym = module.symbols.items[name_ref.index()];
            const start = sym.loc;
            const end = start + @as(u32, @intCast(sym.original_name.len));
            if (offset >= start and offset < end) return name_ref;
        }
        if (findSymbolInDecl(decl, offset)) |found| return found;
    }
    return .none;
}

fn findSymbolInDecl(decl: Ast.Decl, offset: u32) ?Ast.SymbolIndex {
    switch (decl) {
        .function => |f| {
            for (f.parameters.items) |param| {
                if (findSymbolInType(param.typ, offset)) |s| return s;
            }
            if (f.return_type) |rt| {
                if (findSymbolInType(rt, offset)) |s| return s;
            }
            if (f.body) |body| {
                for (body.stmts.items) |stmt| {
                    if (findSymbolInStmt(stmt, offset)) |s| return s;
                }
            }
        },
        .@"struct" => |s| {
            for (s.members.items) |m| {
                if (findSymbolInType(m.typ, offset)) |found| return found;
            }
        },
        .@"const" => |c| {
            if (c.typ) |t| if (findSymbolInType(t, offset)) |s| return s;
            if (c.initializer) |e| if (findSymbolInExpr(e, offset)) |s| return s;
        },
        .override => |o| {
            if (o.typ) |t| if (findSymbolInType(t, offset)) |s| return s;
            if (o.initializer) |e| if (findSymbolInExpr(e, offset)) |s| return s;
        },
        .@"var" => |v| {
            if (v.typ) |t| if (findSymbolInType(t, offset)) |s| return s;
            if (v.initializer) |e| if (findSymbolInExpr(e, offset)) |s| return s;
        },
        .let => |l| {
            if (l.typ) |t| if (findSymbolInType(t, offset)) |s| return s;
            if (l.initializer) |e| if (findSymbolInExpr(e, offset)) |s| return s;
        },
        .alias => |a| {
            if (findSymbolInType(a.typ, offset)) |s| return s;
        },
        .const_assert => |ca| {
            if (findSymbolInExpr(ca.expr, offset)) |s| return s;
        },
    }
    return null;
}

fn findSymbolInType(typ: Ast.Type, offset: u32) ?Ast.SymbolIndex {
    switch (typ) {
        .ident => |t| {
            const end = t.loc + @as(u32, @intCast(t.name.len));
            if (offset >= t.loc and offset < end and t.ref.isValid()) return t.ref;
        },
        .vec => |t| if (t.elem_type) |et| return findSymbolInType(et, offset),
        .mat => |t| if (t.elem_type) |et| return findSymbolInType(et, offset),
        .array => |t| {
            if (t.elem_type) |et| if (findSymbolInType(et, offset)) |s| return s;
            if (t.size) |sz| if (findSymbolInExpr(sz, offset)) |s| return s;
        },
        .ptr => |t| return findSymbolInType(t.elem_type, offset),
        .atomic => |t| return findSymbolInType(t.elem_type, offset),
        .sampler, .texture => {},
    }
    return null;
}

fn findSymbolInStmt(stmt: Ast.Stmt, offset: u32) ?Ast.SymbolIndex {
    switch (stmt) {
        .compound => |c| {
            for (c.stmts.items) |s| if (findSymbolInStmt(s, offset)) |r| return r;
        },
        .@"return" => |r| if (r.value) |v| return findSymbolInExpr(v, offset),
        .@"if" => |i| {
            if (findSymbolInExpr(i.condition, offset)) |s| return s;
            for (i.body.stmts.items) |s| if (findSymbolInStmt(s, offset)) |r| return r;
            if (i.else_branch) |eb| return findSymbolInStmt(eb, offset);
        },
        .@"switch" => |s| {
            if (findSymbolInExpr(s.expr, offset)) |r| return r;
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| if (findSymbolInExpr(sel, offset)) |r| return r;
                for (case.body.stmts.items) |stmt2| if (findSymbolInStmt(stmt2, offset)) |r| return r;
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |is| if (findSymbolInStmt(is, offset)) |r| return r;
            if (f.condition) |c| if (findSymbolInExpr(c, offset)) |r| return r;
            if (f.update) |u| if (findSymbolInStmt(u, offset)) |r| return r;
            for (f.body.stmts.items) |stmt2| if (findSymbolInStmt(stmt2, offset)) |r| return r;
        },
        .@"while" => |w| {
            if (findSymbolInExpr(w.condition, offset)) |r| return r;
            for (w.body.stmts.items) |s| if (findSymbolInStmt(s, offset)) |r| return r;
        },
        .loop => |l| {
            for (l.body.stmts.items) |s| if (findSymbolInStmt(s, offset)) |r| return r;
            if (l.continuing) |cont| {
                for (cont.stmts.items) |s| if (findSymbolInStmt(s, offset)) |r| return r;
            }
        },
        .assign => |a| {
            if (findSymbolInExpr(a.left, offset)) |r| return r;
            if (findSymbolInExpr(a.right, offset)) |r| return r;
        },
        .incr_decr => |i| return findSymbolInExpr(i.expr, offset),
        .call => |c| return findSymbolInExpr(.{ .call = c.call }, offset),
        .decl => |d| return findSymbolInDecl(d.decl, offset),
        .break_if => |b| return findSymbolInExpr(b.condition, offset),
        .@"break", .@"continue", .discard => {},
    }
    return null;
}

fn findSymbolInExpr(expr: Ast.Expr, offset: u32) ?Ast.SymbolIndex {
    switch (expr) {
        .ident => |e| {
            const end = e.loc + @as(u32, @intCast(e.name.len));
            if (offset >= e.loc and offset < end and e.ref.isValid()) return e.ref;
        },
        .member => |e| return findSymbolInExpr(e.base, offset),
        .call => |e| {
            if (e.func) |f| if (findSymbolInExpr(f, offset)) |s| return s;
            if (e.template_type) |tt| if (findSymbolInType(tt, offset)) |s| return s;
            for (e.args.items) |arg| if (findSymbolInExpr(arg, offset)) |s| return s;
        },
        .binary => |e| {
            if (findSymbolInExpr(e.left, offset)) |s| return s;
            if (findSymbolInExpr(e.right, offset)) |s| return s;
        },
        .unary => |e| return findSymbolInExpr(e.operand, offset),
        .index => |e| {
            if (findSymbolInExpr(e.base, offset)) |s| return s;
            if (findSymbolInExpr(e.idx, offset)) |s| return s;
        },
        .paren => |e| return findSymbolInExpr(e.expr, offset),
        .literal => {},
    }
    return null;
}

// =========================================================================
// Reference collection
// =========================================================================

/// Returns every byte range in the source that references `target`.
/// If `include_declaration` is true, the declaration site is included
/// (as `is_write = true`). Caller owns the slice — free with `gpa.free`.
pub fn findReferences(
    gpa: Allocator,
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
    include_declaration: bool,
) Allocator.Error![]Reference {
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
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) Allocator.Error!?[]TextEdit {
    if (!isValidWgslIdentifier(new_name)) return null;
    if (!target.isValid()) return null;

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
