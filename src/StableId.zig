//! Reparse-stable, human-readable IDs for WGSL symbols.
//!
//! `Ast.SymbolIndex` is a fresh `enum(u32)` per parse — it cannot be used as
//! a handle that survives a re-analysis. Byte offsets also shift when the
//! user edits the file. This module produces a structured string ID
//! (`"v1:fn:main/block#0/let:x"`) that round-trips `SymbolIndex → StableId
//! → SymbolIndex` across reparses, and degrades gracefully when the user
//! deletes a symbol.
//!
//! Format:
//!   v1:<segment>[/<segment>]*
//!
//! Each segment is either:
//!   - `<kind>:<name>`              — module-level decl, parameter, struct
//!                                    member, or local symbol (terminal)
//!   - `block#<N>`                  — the Nth compound block at the current
//!                                    scope level (sibling_index among `.block`
//!                                    kind children — see `Ast.ScopeKind`)
//!   - `builtin:<name>`             — a WGSL builtin symbol (no path)
//!
//! Separators `/`, `#`, `:` never appear in WGSL identifiers, so no escaping
//! is required. The `v1:` prefix reserves room for future format changes.
//!
//! Stability contract:
//!   IDs are stable under any edit that does not add, remove, or reorder a
//!   `.block` compound scope at or above the symbol's declaration, and does
//!   not rename a function or struct on the path. Whitespace-only edits,
//!   comment edits, renaming unrelated symbols, and statement-level edits
//!   that do not introduce a new block do not change any existing ID.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Edits = @import("Edits.zig");

/// Maximum length of a generated stable ID, in bytes. Realistic shaders
/// stay well under 200 bytes; the cap exists to reject pathological inputs
/// (extreme nesting combined with very long identifiers).
pub const MAX_LEN: usize = 1024;

/// The `v1:` version prefix. All IDs produced by this module start with
/// this exact byte sequence. Reverse lookup rejects any other prefix.
pub const VERSION_PREFIX: []const u8 = "v1:";

pub const StableId = struct {
    /// Arena-owned bytes, including the `v1:` prefix. Opaque to callers.
    bytes: []const u8,

    pub fn eql(a: StableId, b: StableId) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub const Range = struct { start: u32, end: u32 };

pub const Error = Allocator.Error || error{IdTooLong};

// =========================================================================
// Forward: SymbolIndex → StableId
// =========================================================================

/// Compute the stable ID for `sym` in `module`. Returns null if `sym` is
/// `.none` or out of range. Allocated in `arena`.
///
/// Time: O(N) in the total number of symbols (walks the scope tree to find
/// the owning scope; walks declarations if needed).
pub fn stableIdFor(
    arena: Allocator,
    module: *const Ast.Module,
    sym: Ast.SymbolIndex,
) Error!?StableId {
    if (!sym.isValid()) return null;
    const idx = sym.index();
    if (idx >= module.symbols.items.len) return null;
    const s = module.symbols.items[idx];
    if (s.original_name.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(arena);
    try buf.appendSlice(arena, VERSION_PREFIX);

    if (s.flags.is_builtin or s.kind == .builtin) {
        try buf.appendSlice(arena, "builtin:");
        try buf.appendSlice(arena, s.original_name);
        return try finishId(arena, &buf);
    }

    if (s.kind == .member) {
        const owner_name = findMemberOwnerName(module, sym) orelse return null;
        try buf.appendSlice(arena, "struct:");
        try buf.appendSlice(arena, owner_name);
        try buf.appendSlice(arena, "/member:");
        try buf.appendSlice(arena, s.original_name);
        return try finishId(arena, &buf);
    }

    // All other kinds live in the scope tree. Locate the owning scope and
    // write the path from root down to it, then the terminal segment.
    const owning_scope = findOwningScope(module.scope, sym) orelse return null;
    try writeScopePath(arena, &buf, module, owning_scope);

    const needs_sep = buf.items.len > VERSION_PREFIX.len and
        buf.items[buf.items.len - 1] != ':';
    if (needs_sep) try buf.append(arena, '/');
    try buf.appendSlice(arena, kindString(s.kind));
    try buf.append(arena, ':');
    try buf.appendSlice(arena, s.original_name);

    return try finishId(arena, &buf);
}

/// Convenience: byte offset → stable ID (via `Edits.symbolAtOffset`).
/// Returns null if no symbol covers that offset.
///
/// Mutable receiver because `Edits.symbolAtOffset` walks decl interiors
/// to resolve the offset to a symbol and needs to drain any deferred
/// incremental bias first.
pub fn stableIdAtOffset(
    arena: Allocator,
    module: *Ast.Module,
    offset: u32,
) Error!?StableId {
    const sym = Edits.symbolAtOffset(module, offset);
    return try stableIdFor(arena, module, sym);
}

// =========================================================================
// Reverse: StableId → SymbolIndex
// =========================================================================

/// Resolve a stable ID back to a `SymbolIndex` in the given module.
/// Returns `.none` if the ID does not parse, starts with an unknown version
/// prefix, or references a symbol that no longer exists.
pub fn symbolForStableId(
    module: *const Ast.Module,
    id_bytes: []const u8,
) Ast.SymbolIndex {
    if (!std.mem.startsWith(u8, id_bytes, VERSION_PREFIX)) return .none;
    const body = id_bytes[VERSION_PREFIX.len..];
    if (body.len == 0) return .none;
    if (body.len > MAX_LEN) return .none;

    var it = std.mem.splitScalar(u8, body, '/');
    const first = it.next() orelse return .none;

    // `builtin:<name>` → root-scope lookup, must match kind.
    if (std.mem.startsWith(u8, first, "builtin:")) {
        if (it.next() != null) return .none;
        const name = first["builtin:".len..];
        if (name.len == 0) return .none;
        const ref = lookupMember(module.scope, name) orelse return .none;
        const s = module.symbols.items[ref.index()];
        if (!s.flags.is_builtin and s.kind != .builtin) return .none;
        return ref;
    }

    const first_parsed = parseKindName(first) orelse return .none;

    if (first_parsed.kind == .@"struct") {
        const next = it.next();
        if (next == null) {
            // Terminal `struct:S`.
            return expectModuleKind(module, first_parsed.name, .@"struct");
        }
        // `struct:S/member:F` — must be the final segment.
        if (it.next() != null) return .none;
        const parsed = parseKindName(next.?) orelse return .none;
        if (parsed.kind != .member) return .none;
        return findMemberSymbol(module, first_parsed.name, parsed.name);
    }

    if (first_parsed.kind == .function) {
        // `fn:F` [ scope-segments+ terminal ]
        if (it.peek() == null) {
            // Terminal — the function itself.
            return expectModuleKind(module, first_parsed.name, .function);
        }
        const fn_scope = findFunctionScope(module, first_parsed.name) orelse return .none;
        return walkAndResolve(module, fn_scope, &it);
    }

    // A bare terminal at module scope: `const:x`, `var:x`, `alias:x`,
    // `override:x`, `let:x`.
    if (it.next() != null) return .none;
    return expectModuleKind(module, first_parsed.name, first_parsed.kind);
}

/// Convenience: stable ID → the byte range of the declared *name* in
/// the current source. Returns null if the ID does not resolve.
pub fn locateStableId(
    module: *const Ast.Module,
    id_bytes: []const u8,
) ?Range {
    const sym = symbolForStableId(module, id_bytes);
    if (!sym.isValid()) return null;
    const s = module.symbols.items[sym.index()];
    return .{
        .start = s.loc,
        .end = s.loc + @as(u32, @intCast(s.original_name.len)),
    };
}

/// Returns the full syntactic span of the declaration identified by
/// `id_bytes` (attributes + keyword + body/`;`). Returns null if the ID
/// does not resolve, is a builtin, or targets a struct member or
/// parameter (those are not standalone declarations — use
/// `locateStableId` for their name range).
pub fn locateDeclaration(
    module: *Ast.Module,
    id_bytes: []const u8,
) ?Range {
    const sym = symbolForStableId(module, id_bytes);
    if (!sym.isValid()) return null;

    for (module.declarations.items) |decl| {
        if (decl.nameRef() == sym) {
            const span = decl.declSpan();
            if (span.isEmpty()) return null;
            return .{ .start = span.start, .end = span.end };
        }
        // Descend into function bodies for local let/var/const.
        switch (decl) {
            .function => |f| if (f.body) |body| {
                if (findLocalDeclSpan(body, sym)) |r| return r;
            },
            else => {},
        }
    }
    return null;
}

/// Returns the span of the type annotation attached to the symbol
/// identified by `id_bytes`. Works for:
///   - struct members (always typed)
///   - function parameters (always typed)
///   - function return types (pass the function's stable ID)
///   - `var`/`const`/`override`/`let` with an explicit `: T` annotation
/// Returns null if the ID does not resolve or the target has no type
/// annotation.
///
/// Mutable receiver because type spans live in decl interiors — if the
/// module carries deferred incremental bias (`interior_pending`), it is
/// drained before the read.
pub fn locateType(
    module: *Ast.Module,
    id_bytes: []const u8,
) ?Range {
    module.absorbInteriors();
    const sym = symbolForStableId(module, id_bytes);
    if (!sym.isValid()) return null;

    for (module.declarations.items) |decl| {
        if (decl.nameRef() == sym) {
            const typ_opt: ?Ast.Type = switch (decl) {
                .@"const" => |c| c.typ,
                .override => |o| o.typ,
                .@"var" => |v| v.typ,
                .let => |l| l.typ,
                .alias => |a| a.typ,
                .function => |f| f.return_type, // function → return type
                .@"struct", .const_assert => null,
            };
            if (typ_opt) |t| {
                const sp = t.span();
                if (sp.isEmpty()) return null;
                return .{ .start = sp.start, .end = sp.end };
            }
            return null;
        }
        switch (decl) {
            .function => |f| {
                for (f.parameters.items) |p| {
                    if (p.name == sym) {
                        const sp = p.typ.span();
                        if (sp.isEmpty()) return null;
                        return .{ .start = sp.start, .end = sp.end };
                    }
                }
                if (f.body) |body| {
                    if (findLocalTypeSpan(body, sym)) |r| return r;
                }
            },
            .@"struct" => |st| {
                for (st.members.items) |m| {
                    if (m.name == sym) {
                        const sp = m.typ.span();
                        if (sp.isEmpty()) return null;
                        return .{ .start = sp.start, .end = sp.end };
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn findLocalDeclSpan(compound: *const Ast.CompoundStmt, target: Ast.SymbolIndex) ?Range {
    for (compound.stmts.items) |stmt| {
        if (findLocalDeclSpanStmt(stmt, target)) |r| return r;
    }
    return null;
}

fn findLocalDeclSpanStmt(stmt: Ast.Stmt, target: Ast.SymbolIndex) ?Range {
    switch (stmt) {
        .compound => |c| return findLocalDeclSpan(c, target),
        .@"if" => |i| {
            if (findLocalDeclSpan(i.body, target)) |r| return r;
            if (i.else_branch) |eb| return findLocalDeclSpanStmt(eb, target);
        },
        .@"switch" => |sw| for (sw.cases.items) |case| {
            if (findLocalDeclSpan(case.body, target)) |r| return r;
        },
        .@"for" => |f| {
            if (f.init_stmt) |is| if (findLocalDeclSpanStmt(is, target)) |r| return r;
            if (findLocalDeclSpan(f.body, target)) |r| return r;
        },
        .@"while" => |w| if (findLocalDeclSpan(w.body, target)) |r| return r,
        .loop => |l| {
            if (findLocalDeclSpan(l.body, target)) |r| return r;
            if (l.continuing) |cont| if (findLocalDeclSpan(cont, target)) |r| return r;
        },
        .decl => |d| {
            if (d.decl.nameRef() == target) {
                const span = d.decl.declSpan();
                if (span.isEmpty()) return null;
                return .{ .start = span.start, .end = span.end };
            }
        },
        else => {},
    }
    return null;
}

fn findLocalTypeSpan(compound: *const Ast.CompoundStmt, target: Ast.SymbolIndex) ?Range {
    for (compound.stmts.items) |stmt| {
        if (findLocalTypeSpanStmt(stmt, target)) |r| return r;
    }
    return null;
}

fn findLocalTypeSpanStmt(stmt: Ast.Stmt, target: Ast.SymbolIndex) ?Range {
    switch (stmt) {
        .compound => |c| return findLocalTypeSpan(c, target),
        .@"if" => |i| {
            if (findLocalTypeSpan(i.body, target)) |r| return r;
            if (i.else_branch) |eb| return findLocalTypeSpanStmt(eb, target);
        },
        .@"switch" => |sw| for (sw.cases.items) |case| {
            if (findLocalTypeSpan(case.body, target)) |r| return r;
        },
        .@"for" => |f| {
            if (f.init_stmt) |is| if (findLocalTypeSpanStmt(is, target)) |r| return r;
            if (findLocalTypeSpan(f.body, target)) |r| return r;
        },
        .@"while" => |w| if (findLocalTypeSpan(w.body, target)) |r| return r,
        .loop => |l| {
            if (findLocalTypeSpan(l.body, target)) |r| return r;
            if (l.continuing) |cont| if (findLocalTypeSpan(cont, target)) |r| return r;
        },
        .decl => |d| {
            if (d.decl.nameRef() == target) {
                const typ_opt: ?Ast.Type = switch (d.decl) {
                    .@"const" => |c| c.typ,
                    .@"var" => |v| v.typ,
                    .let => |l| l.typ,
                    else => null,
                };
                if (typ_opt) |t| {
                    const sp = t.span();
                    if (sp.isEmpty()) return null;
                    return .{ .start = sp.start, .end = sp.end };
                }
            }
        },
        else => {},
    }
    return null;
}

// =========================================================================
// Kind encoding / decoding
// =========================================================================

fn kindString(kind: Ast.Symbol.Kind) []const u8 {
    return switch (kind) {
        .function => "fn",
        .@"struct" => "struct",
        .alias => "alias",
        .@"const" => "const",
        .override => "override",
        .@"var" => "var",
        .let => "let",
        .parameter => "param",
        .member => "member",
        .builtin => "builtin",
        .unbound => "unbound",
    };
}

fn kindFromString(s: []const u8) ?Ast.Symbol.Kind {
    if (std.mem.eql(u8, s, "fn")) return .function;
    if (std.mem.eql(u8, s, "struct")) return .@"struct";
    if (std.mem.eql(u8, s, "alias")) return .alias;
    if (std.mem.eql(u8, s, "const")) return .@"const";
    if (std.mem.eql(u8, s, "override")) return .override;
    if (std.mem.eql(u8, s, "var")) return .@"var";
    if (std.mem.eql(u8, s, "let")) return .let;
    if (std.mem.eql(u8, s, "param")) return .parameter;
    if (std.mem.eql(u8, s, "member")) return .member;
    return null;
}

const KindName = struct { kind: Ast.Symbol.Kind, name: []const u8 };

fn parseKindName(seg: []const u8) ?KindName {
    const colon = std.mem.indexOfScalar(u8, seg, ':') orelse return null;
    const k = kindFromString(seg[0..colon]) orelse return null;
    const name = seg[colon + 1 ..];
    if (name.len == 0) return null;
    return .{ .kind = k, .name = name };
}

// =========================================================================
// Scope walking
// =========================================================================

/// Locate the scope whose `members` map contains `sym`. Returns null for
/// builtins and struct members (they are not in the scope tree).
fn findOwningScope(root: *const Ast.Scope, sym: Ast.SymbolIndex) ?*const Ast.Scope {
    var it = root.members.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.ref == sym) return root;
    }
    for (root.children.items) |child| {
        if (findOwningScope(child, sym)) |s| return s;
    }
    return null;
}

/// Append the path from the module root down to `target` to `buf`. The
/// module root itself contributes nothing. A `.function` scope contributes
/// `fn:<name>`; a `.block` scope contributes `block#<sibling_index>`.
fn writeScopePath(
    arena: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    module: *const Ast.Module,
    target: *const Ast.Scope,
) Error!void {
    var chain: [128]*const Ast.Scope = undefined;
    var depth: usize = 0;
    var cur: ?*const Ast.Scope = target;
    while (cur) |s| : (cur = s.parent) {
        if (depth >= chain.len) return error.IdTooLong;
        chain[depth] = s;
        depth += 1;
    }
    // chain[0..depth] is target→root; walk root→target.
    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const s = chain[i];
        if (s.parent == null) continue; // skip module root
        const needs_sep = buf.items.len > VERSION_PREFIX.len and
            buf.items[buf.items.len - 1] != ':';
        if (needs_sep) try buf.append(arena, '/');
        switch (s.kind) {
            .module => unreachable,
            .function => {
                const name = functionScopeName(module, s) orelse return error.IdTooLong;
                try buf.appendSlice(arena, "fn:");
                try buf.appendSlice(arena, name);
            },
            .block => {
                var scratch: [24]u8 = undefined;
                const slice = std.fmt.bufPrint(&scratch, "block#{d}", .{s.sibling_index}) catch
                    return error.IdTooLong;
                try buf.appendSlice(arena, slice);
            },
        }
    }
}

/// Given a `.function` scope, return the function's original name.
///
/// WGSL has no nested functions, so a function scope's parent is always the
/// module scope. The k-th `.function` child of the module scope corresponds
/// to the k-th `.function`-kind symbol in the module (in declaration
/// order). We recover the name by iterating `module.declarations`.
fn functionScopeName(module: *const Ast.Module, fn_scope: *const Ast.Scope) ?[]const u8 {
    const parent = fn_scope.parent orelse return null;

    // Determine which function-kind child this is.
    var nth: u32 = 0;
    var found = false;
    for (parent.children.items) |c| {
        if (c == fn_scope) {
            found = true;
            break;
        }
        if (c.kind == .function) nth += 1;
    }
    if (!found) return null;

    // Walk module.declarations in source order, picking the nth function.
    var seen: u32 = 0;
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                if (seen == nth) {
                    return module.symbols.items[f.name.index()].original_name;
                }
                seen += 1;
            },
            else => {},
        }
    }
    return null;
}

/// Find the function scope for a function declared at module scope by name.
fn findFunctionScope(module: *const Ast.Module, name: []const u8) ?*const Ast.Scope {
    // Resolve the function symbol on the module scope and match kind.
    const ref = lookupMember(module.scope, name) orelse return null;
    const sym = module.symbols.items[ref.index()];
    if (sym.kind != .function) return null;

    // Count how many function declarations appear before this one in
    // declaration order.
    var nth: u32 = 0;
    for (module.declarations.items) |decl| switch (decl) {
        .function => |f| {
            if (!f.name.isValid()) continue;
            if (f.name == ref) break;
            nth += 1;
        },
        else => {},
    };

    // Return the nth `.function` child of the module scope.
    var seen: u32 = 0;
    for (module.scope.children.items) |c| {
        if (c.kind != .function) continue;
        if (seen == nth) return c;
        seen += 1;
    }
    return null;
}

fn lookupMember(scope: *const Ast.Scope, name: []const u8) ?Ast.SymbolIndex {
    if (scope.members.get(name)) |m| return m.ref;
    return null;
}

fn expectModuleKind(
    module: *const Ast.Module,
    name: []const u8,
    kind: Ast.Symbol.Kind,
) Ast.SymbolIndex {
    const ref = lookupMember(module.scope, name) orelse return .none;
    const s = module.symbols.items[ref.index()];
    if (s.kind != kind) return .none;
    return ref;
}

fn findMemberOwnerName(module: *const Ast.Module, sym: Ast.SymbolIndex) ?[]const u8 {
    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"struct" => |st| {
                for (st.members.items) |m| {
                    if (m.name == sym) {
                        if (!st.name.isValid()) return null;
                        return module.symbols.items[st.name.index()].original_name;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn findMemberSymbol(
    module: *const Ast.Module,
    struct_name: []const u8,
    member_name: []const u8,
) Ast.SymbolIndex {
    for (module.declarations.items) |decl| switch (decl) {
        .@"struct" => |st| {
            if (!st.name.isValid()) continue;
            const sname = module.symbols.items[st.name.index()].original_name;
            if (!std.mem.eql(u8, sname, struct_name)) continue;
            for (st.members.items) |m| {
                if (!m.name.isValid()) continue;
                const mname = module.symbols.items[m.name.index()].original_name;
                if (std.mem.eql(u8, mname, member_name)) return m.name;
            }
            return .none;
        },
        else => {},
    };
    return .none;
}

const SegIter = std.mem.SplitIterator(u8, .scalar);

fn walkAndResolve(
    module: *const Ast.Module,
    start: *const Ast.Scope,
    it: *SegIter,
) Ast.SymbolIndex {
    var cur: *const Ast.Scope = start;

    while (it.next()) |seg| {
        if (std.mem.indexOfScalar(u8, seg, ':')) |_| {
            // Terminal `kind:name`.
            if (it.next() != null) return .none;
            const parsed = parseKindName(seg) orelse return .none;
            if (parsed.kind == .member or parsed.kind == .builtin or parsed.kind == .unbound) {
                return .none;
            }
            const ref = lookupMember(cur, parsed.name) orelse return .none;
            const sym = module.symbols.items[ref.index()];
            if (sym.kind != parsed.kind) return .none;
            return ref;
        }

        // Scope anchor: `block#<N>`.
        if (std.mem.startsWith(u8, seg, "block#")) {
            const n_str = seg["block#".len..];
            const n = std.fmt.parseInt(u32, n_str, 10) catch return .none;
            const next = findSiblingByIndex(cur, .block, n) orelse return .none;
            cur = next;
            continue;
        }

        return .none;
    }
    return .none;
}

fn findSiblingByIndex(
    parent: *const Ast.Scope,
    kind: Ast.ScopeKind,
    n: u32,
) ?*const Ast.Scope {
    for (parent.children.items) |c| {
        if (c.kind == kind and c.sibling_index == n) return c;
    }
    return null;
}

fn finishId(arena: Allocator, buf: *std.ArrayListUnmanaged(u8)) Error!StableId {
    if (buf.items.len > MAX_LEN) return error.IdTooLong;
    const bytes = try arena.dupe(u8, buf.items);
    return .{ .bytes = bytes };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

fn parseForTest(arena: Allocator, source: [:0]const u8) !*Ast.Module {
    const tokens = try Lexer.tokenize(arena, source);
    var parser = try Parser.init(arena, source, tokens);
    return try parser.parse();
}

test "StableId: module function roundtrip" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const module = try parseForTest(a, "fn main() {}");

    const main_sym = lookupMember(module.scope, "main").?;
    const id = (try stableIdFor(a, module, main_sym)).?;
    try testing.expectEqualStrings("v1:fn:main", id.bytes);

    try testing.expectEqual(main_sym, symbolForStableId(module, id.bytes));
}

test "StableId: struct and member roundtrip" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const module = try parseForTest(a, "struct Vertex { position: f32, color: f32 }");

    const st_sym = lookupMember(module.scope, "Vertex").?;
    const st_id = (try stableIdFor(a, module, st_sym)).?;
    try testing.expectEqualStrings("v1:struct:Vertex", st_id.bytes);
    try testing.expectEqual(st_sym, symbolForStableId(module, st_id.bytes));

    var pos_sym: Ast.SymbolIndex = .none;
    for (module.declarations.items) |decl| switch (decl) {
        .@"struct" => |st| for (st.members.items) |m| {
            const s = module.symbols.items[m.name.index()];
            if (std.mem.eql(u8, s.original_name, "position")) pos_sym = m.name;
        },
        else => {},
    };
    try testing.expect(pos_sym.isValid());

    const pos_id = (try stableIdFor(a, module, pos_sym)).?;
    try testing.expectEqualStrings("v1:struct:Vertex/member:position", pos_id.bytes);
    try testing.expectEqual(pos_sym, symbolForStableId(module, pos_id.bytes));
}

test "StableId: local in function body" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const module = try parseForTest(a, "fn main() { let x = 1; }");

    // Locate the `let x` symbol: kind .let, original_name "x".
    var x_sym: Ast.SymbolIndex = .none;
    for (module.symbols.items, 0..) |s, i| {
        if (s.kind == .let and std.mem.eql(u8, s.original_name, "x")) {
            x_sym = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    try testing.expect(x_sym.isValid());

    const id = (try stableIdFor(a, module, x_sym)).?;
    try testing.expectEqualStrings("v1:fn:main/block#0/let:x", id.bytes);
    try testing.expectEqual(x_sym, symbolForStableId(module, id.bytes));
}

test "StableId: parameter" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const module = try parseForTest(a, "fn f(x: f32) {}");

    var p_sym: Ast.SymbolIndex = .none;
    for (module.symbols.items, 0..) |s, i| {
        if (s.kind == .parameter and std.mem.eql(u8, s.original_name, "x")) {
            p_sym = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    try testing.expect(p_sym.isValid());

    const id = (try stableIdFor(a, module, p_sym)).?;
    try testing.expectEqualStrings("v1:fn:f/param:x", id.bytes);
    try testing.expectEqual(p_sym, symbolForStableId(module, id.bytes));
}

test "StableId: sibling blocks shadow each other" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const src: [:0]const u8 =
        \\fn main() {
        \\  if (true) { let x = 1; }
        \\  if (true) { let x = 2; }
        \\}
    ;
    const module = try parseForTest(a, src);

    // Collect both `x` symbols by loc order.
    var xs: [2]Ast.SymbolIndex = .{ .none, .none };
    var n: usize = 0;
    for (module.symbols.items, 0..) |s, i| {
        if (s.kind == .let and std.mem.eql(u8, s.original_name, "x")) {
            if (n < xs.len) {
                xs[n] = @enumFromInt(@as(u32, @intCast(i)));
                n += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), n);

    const id0 = (try stableIdFor(a, module, xs[0])).?;
    const id1 = (try stableIdFor(a, module, xs[1])).?;

    // The function body is block#0 (of the function scope); the two if
    // bodies are block#0 and block#1 (of the function body block).
    try testing.expectEqualStrings("v1:fn:main/block#0/block#0/let:x", id0.bytes);
    try testing.expectEqualStrings("v1:fn:main/block#0/block#1/let:x", id1.bytes);

    try testing.expectEqual(xs[0], symbolForStableId(module, id0.bytes));
    try testing.expectEqual(xs[1], symbolForStableId(module, id1.bytes));
}

test "StableId: stale ID returns .none after reparse without that symbol" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();

    const src1: [:0]const u8 = "fn main() { let x = 1; }";
    var id_bytes: []u8 = undefined;
    {
        const m = try parseForTest(a, src1);
        var x_sym: Ast.SymbolIndex = .none;
        for (m.symbols.items, 0..) |s, i| if (s.kind == .let and std.mem.eql(u8, s.original_name, "x")) {
            x_sym = @enumFromInt(@as(u32, @intCast(i)));
        };
        const id = (try stableIdFor(a, m, x_sym)).?;
        id_bytes = try a.dupe(u8, id.bytes);
    }

    // Reparse source that no longer has `x`.
    const src2: [:0]const u8 = "fn main() {}";
    const m2 = try parseForTest(a, src2);
    try testing.expectEqual(Ast.SymbolIndex.none, symbolForStableId(m2, id_bytes));
}

test "StableId: unknown version prefix rejected" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const a = aa.allocator();
    const module = try parseForTest(a, "fn main() {}");

    try testing.expectEqual(Ast.SymbolIndex.none, symbolForStableId(module, "v2:fn:main"));
    try testing.expectEqual(Ast.SymbolIndex.none, symbolForStableId(module, "fn:main"));
    try testing.expectEqual(Ast.SymbolIndex.none, symbolForStableId(module, ""));
    try testing.expectEqual(Ast.SymbolIndex.none, symbolForStableId(module, "v1:"));
}
