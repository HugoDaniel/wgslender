//! Deep structural equality helpers for `Ast.Module`.
//!
//! The gate is `expectModulesEquivalent`: it proves an incremental hot-path
//! splice is semantically identical to a fresh full parse of the same edited
//! source — same shape, symbols, scopes, decl/stmt/expr/type trees, and
//! `use_count`s — modulo the hot path's append-only symbol table. Error lists
//! are NOT compared. Used by `tests/incremental_fuzz_test.zig` and
//! `tests/incremental_mutation_test.zig`.

const std = @import("std");
const wgslender = @import("wgslender");
const Ast = wgslender.Ast;

// ---------------------------------------------------------------------------
// Symbol-reference comparison.
//
// `SymbolIndex` values are raw indices into a module's symbol array. An
// *incremental hot-path* module compared against a fresh full parse cannot
// compare refs by index: the hot path's symbol table is append-only (removed
// declarations leave a stale, use_count==0 symbol in place), so every symbol
// after the first removal is index-shifted relative to the compact full-parse
// table. Refs are therefore matched by the *resolved symbol name*.
//
// `expectModulesEquivalent` publishes the two symbol tables used to resolve
// those names; every leaf comparison of a `SymbolIndex` goes through
// `sameRef`. Tests are single-threaded, so file-scope state is safe and keeps
// the comparator signatures unchanged.
var exp_syms: []const Ast.Symbol = &.{};
var act_syms: []const Ast.Symbol = &.{};

fn symName(syms: []const Ast.Symbol, ref: Ast.SymbolIndex) []const u8 {
    if (!ref.isValid()) return "";
    const i = ref.index();
    return if (i < syms.len) syms[i].original_name else "<oob>";
}

/// Compare an expected vs actual `SymbolIndex` by resolved declaration name,
/// so a stale-symbol index shift between a hot-path splice and a full parse
/// does not read as a mismatch.
fn sameRef(e: Ast.SymbolIndex, a: Ast.SymbolIndex) bool {
    if (e.isValid() != a.isValid()) return false;
    if (!e.isValid()) return true;
    return std.mem.eql(u8, symName(exp_syms, e), symName(act_syms, a));
}

/// All the concrete mismatch tags the helpers below can fail with. Declared
/// as a single union so Zig can resolve mutual recursion between expr/type/
/// stmt/decl comparators without inferring divergent error sets.
pub const Err = error{
    SymbolsLenMismatch,
    DirectivesLenMismatch,
    DeclarationsLenMismatch,
    SymbolNameMismatch,
    SymbolKindMismatch,
    SymbolFlagsMismatch,
    SymbolUseCountMismatch,
    UseCountsLenMismatch,
    SymbolLocMismatch,
    ScopeKindMismatch,
    ScopeSiblingMismatch,
    ScopeMembersCountMismatch,
    ScopeMemberMissing,
    ScopeMemberRefMismatch,
    ScopeMemberLocMismatch,
    ScopeChildCountMismatch,
    DirectiveTagMismatch,
    DirectiveSpanMismatch,
    DirectiveFeaturesLenMismatch,
    DirectiveFeatureMismatch,
    DirectiveSeverityMismatch,
    DirectiveRuleMismatch,
    DeclTagMismatch,
    DeclSpanMismatch,
    DeclNameMismatch,
    VarAddrSpaceMismatch,
    VarAccessModeMismatch,
    FuncNameMismatch,
    FuncParamCountMismatch,
    ParamNameMismatch,
    StructNameMismatch,
    StructMemberCountMismatch,
    StructMemberNameMismatch,
    AliasNameMismatch,
    AttributesLenMismatch,
    AttrNameMismatch,
    AttrLocMismatch,
    AttrSpanMismatch,
    AttrArgCountMismatch,
    OptTypePresenceMismatch,
    TypeTagMismatch,
    TypeSpanMismatch,
    IdentTypeNameMismatch,
    IdentTypeRefMismatch,
    IdentTypeLocMismatch,
    VecSizeMismatch,
    VecLocMismatch,
    MatShapeMismatch,
    MatLocMismatch,
    PtrAddrMismatch,
    PtrAccessMismatch,
    AtomicLocMismatch,
    SamplerCompMismatch,
    TextureKindMismatch,
    TextureDimMismatch,
    TextureAccessMismatch,
    TextureFormatMismatch,
    OptExprPresenceMismatch,
    ExprTagMismatch,
    ExprSpanMismatch,
    IdentExprNameMismatch,
    IdentExprRefMismatch,
    IdentExprLocMismatch,
    IdentExprFlagsMismatch,
    LiteralKindMismatch,
    LiteralValueMismatch,
    LiteralLocMismatch,
    LiteralFlagsMismatch,
    BinaryOpMismatch,
    BinaryLocMismatch,
    BinaryFlagsMismatch,
    UnaryOpMismatch,
    UnaryLocMismatch,
    UnaryFlagsMismatch,
    CallLocMismatch,
    CallEndLocMismatch,
    CallArgCountMismatch,
    IndexLocMismatch,
    MemberLocMismatch,
    MemberNameMismatch,
    OptCompoundPresenceMismatch,
    CompoundSpanMismatch,
    CompoundLenMismatch,
    StmtTagMismatch,
    StmtSpanMismatch,
    ReturnLocMismatch,
    ElseBranchMismatch,
    SwitchCaseCountMismatch,
    SwitchSelectorCountMismatch,
    ForInitPresenceMismatch,
    ForUpdatePresenceMismatch,
    LoopContPresenceMismatch,
    BreakLocMismatch,
    ContinueLocMismatch,
    DiscardLocMismatch,
    AssignOpMismatch,
    AssignLocMismatch,
    PhonyLocMismatch,
    IncrDecrOpMismatch,
    IncrDecrLocMismatch,
    TestExpectedEqual,
} || std.mem.Allocator.Error;

/// Stale-symbol-tolerant equivalence: `actual` (an incremental hot-path
/// splice) must be semantically identical to `expected` (a fresh full parse
/// of the same edited source), *modulo* the hot path's append-only symbol
/// table. Every full-parse symbol must have a matching (name, kind,
/// use_count) symbol in the splice; any extra splice symbols must be dead
/// (use_count == 0). Declaration trees, spans, flags, and scope structure
/// are compared exactly, with symbol references resolved by name (see
/// `sameRef`) so the stale-symbol index shift does not read as a mismatch.
///
/// This is the gate that keeps the Parser-driven anchor splice honest once
/// `CstLower` is gone — see `tests/incremental_fuzz_test.zig`.
pub fn expectModulesEquivalent(
    gpa: std.mem.Allocator,
    expected: *const Ast.Module,
    actual: *const Ast.Module,
) Err!void {
    exp_syms = expected.symbols.items;
    act_syms = actual.symbols.items;
    defer {
        exp_syms = &.{};
        act_syms = &.{};
    }

    try std.testing.expectEqualStrings(expected.source, actual.source);

    // Symbols + use-counts, tolerant of the append-only hot-path table.
    try expectSymbolsEquivalent(gpa, expected, actual);

    // Directives.
    if (expected.directives.items.len != actual.directives.items.len) return error.DirectivesLenMismatch;
    for (expected.directives.items, actual.directives.items) |e, a| {
        try expectDirectiveEqual(e, a);
    }

    // Declarations — deep tree compare (refs resolved by name).
    if (expected.declarations.items.len != actual.declarations.items.len) {
        std.debug.print(
            "declarations.len mismatch: expected {d}, actual {d}\n",
            .{ expected.declarations.items.len, actual.declarations.items.len },
        );
        return error.DeclarationsLenMismatch;
    }
    for (expected.declarations.items, actual.declarations.items) |e, a| {
        try expectDeclEqual(e, a);
    }

    // Scope tree (member refs resolved by name; stale symbols never become
    // scope members, so member counts still match a full parse).
    try expectScopeEqual(expected.scope, actual.scope);
}

/// Match every `expected` symbol to a distinct `actual` symbol by
/// (name, kind, use_count); leftover `actual` symbols must be dead
/// (use_count == 0). Mirrors the append-only contract asserted by
/// `tests/incremental_mutation_test.zig`'s `expectSymbolsMatch`.
fn expectSymbolsEquivalent(
    gpa: std.mem.Allocator,
    expected: *const Ast.Module,
    actual: *const Ast.Module,
) Err!void {
    const matched = try gpa.alloc(bool, actual.symbols.items.len);
    defer gpa.free(matched);
    @memset(matched, false);

    for (expected.symbols.items, 0..) |se, ei| {
        const se_uc: u32 = if (ei < expected.use_counts.counts.len) expected.use_counts.counts[ei] else 0;
        var found = false;
        for (actual.symbols.items, 0..) |sa, ai| {
            if (matched[ai]) continue;
            if (sa.kind != se.kind) continue;
            const sa_uc: u32 = if (ai < actual.use_counts.counts.len) actual.use_counts.counts[ai] else 0;
            if (sa_uc != se_uc) continue;
            if (!std.mem.eql(u8, sa.original_name, se.original_name)) continue;
            matched[ai] = true;
            found = true;
            break;
        }
        if (!found) {
            std.debug.print(
                "expected symbol '{s}' (kind={s}, use={d}) has no match in the splice\n",
                .{ se.original_name, @tagName(se.kind), se_uc },
            );
            return error.SymbolsLenMismatch;
        }
    }
    for (actual.symbols.items, matched, 0..) |sa, m, ai| {
        if (m) continue;
        const sa_uc: u32 = if (ai < actual.use_counts.counts.len) actual.use_counts.counts[ai] else 0;
        if (sa_uc != 0) {
            std.debug.print(
                "unmatched splice symbol '{s}' (kind={s}, use={d}) is not dead\n",
                .{ sa.original_name, @tagName(sa.kind), sa_uc },
            );
            return error.SymbolUseCountMismatch;
        }
    }
}

fn expectScopeEqual(e: *Ast.Scope, a: *Ast.Scope) Err!void {
    if (e.kind != a.kind) return error.ScopeKindMismatch;
    if (e.sibling_index != a.sibling_index) return error.ScopeSiblingMismatch;
    if (e.members.count() != a.members.count()) {
        std.debug.print(
            "scope kind={s} members mismatch: expected {d} vs actual {d}\n",
            .{ @tagName(e.kind), e.members.count(), a.members.count() },
        );
        return error.ScopeMembersCountMismatch;
    }
    var iter = e.members.iterator();
    while (iter.next()) |entry| {
        const am = a.members.get(entry.key_ptr.*) orelse return error.ScopeMemberMissing;
        if (!sameRef(entry.value_ptr.ref, am.ref)) return error.ScopeMemberRefMismatch;
        if (am.loc != entry.value_ptr.loc) return error.ScopeMemberLocMismatch;
    }
    if (e.children.items.len != a.children.items.len) return error.ScopeChildCountMismatch;
    for (e.children.items, a.children.items) |ec, ac| {
        try expectScopeEqual(ec, ac);
    }
}

fn expectDirectiveEqual(e: Ast.Directive, a: Ast.Directive) Err!void {
    if (@intFromEnum(std.meta.activeTag(e)) != @intFromEnum(std.meta.activeTag(a))) {
        return error.DirectiveTagMismatch;
    }
    switch (e) {
        .enable => |ed| {
            const ad = a.enable;
            if (ed.span.start != ad.span.start or ed.span.end != ad.span.end) return error.DirectiveSpanMismatch;
            if (ed.features.items.len != ad.features.items.len) return error.DirectiveFeaturesLenMismatch;
            for (ed.features.items, ad.features.items) |ef, af| {
                if (!std.mem.eql(u8, ef, af)) return error.DirectiveFeatureMismatch;
            }
        },
        .requires => |ed| {
            const ad = a.requires;
            if (ed.span.start != ad.span.start or ed.span.end != ad.span.end) return error.DirectiveSpanMismatch;
            if (ed.features.items.len != ad.features.items.len) return error.DirectiveFeaturesLenMismatch;
            for (ed.features.items, ad.features.items) |ef, af| {
                if (!std.mem.eql(u8, ef, af)) return error.DirectiveFeatureMismatch;
            }
        },
        .diagnostic => |ed| {
            const ad = a.diagnostic;
            if (ed.span.start != ad.span.start or ed.span.end != ad.span.end) return error.DirectiveSpanMismatch;
            if (!std.mem.eql(u8, ed.severity, ad.severity)) return error.DirectiveSeverityMismatch;
            if (!std.mem.eql(u8, ed.rule, ad.rule)) return error.DirectiveRuleMismatch;
        },
    }
}

fn expectDeclEqual(e: Ast.Decl, a: Ast.Decl) Err!void {
    if (@intFromEnum(std.meta.activeTag(e)) != @intFromEnum(std.meta.activeTag(a))) {
        std.debug.print("decl tag mismatch: {s} vs {s}\n", .{ @tagName(std.meta.activeTag(e)), @tagName(std.meta.activeTag(a)) });
        return error.DeclTagMismatch;
    }
    if (e.declSpan().start != a.declSpan().start or e.declSpan().end != a.declSpan().end) {
        std.debug.print("decl span mismatch: {d}..{d} vs {d}..{d}\n", .{ e.declSpan().start, e.declSpan().end, a.declSpan().start, a.declSpan().end });
        return error.DeclSpanMismatch;
    }
    switch (e) {
        .@"const" => |ed| {
            const ad = a.@"const";
            if (!sameRef(ed.name, ad.name)) return error.DeclNameMismatch;
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .override => |ed| {
            const ad = a.override;
            if (!sameRef(ed.name, ad.name)) return error.DeclNameMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .@"var" => |ed| {
            const ad = a.@"var";
            if (!sameRef(ed.name, ad.name)) return error.DeclNameMismatch;
            if (ed.address_space != ad.address_space) return error.VarAddrSpaceMismatch;
            if (ed.access_mode != ad.access_mode) return error.VarAccessModeMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .let => |ed| {
            const ad = a.let;
            if (!sameRef(ed.name, ad.name)) return error.DeclNameMismatch;
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .function => |ed| {
            const ad = a.function;
            if (!sameRef(ed.name, ad.name)) return error.FuncNameMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectAttributesEqual(ed.return_attr, ad.return_attr);
            if (ed.parameters.items.len != ad.parameters.items.len) return error.FuncParamCountMismatch;
            for (ed.parameters.items, ad.parameters.items) |ep, ap| {
                if (!sameRef(ep.name, ap.name)) return error.ParamNameMismatch;
                try expectAttributesEqual(ep.attributes, ap.attributes);
                try expectTypeEqual(ep.typ, ap.typ);
            }
            try expectOptTypeEqual(ed.return_type, ad.return_type);
            try expectOptCompoundEqual(ed.body, ad.body);
        },
        .@"struct" => |ed| {
            const ad = a.@"struct";
            if (!sameRef(ed.name, ad.name)) return error.StructNameMismatch;
            if (ed.members.items.len != ad.members.items.len) return error.StructMemberCountMismatch;
            for (ed.members.items, ad.members.items) |em, am| {
                if (!sameRef(em.name, am.name)) return error.StructMemberNameMismatch;
                try expectAttributesEqual(em.attributes, am.attributes);
                try expectTypeEqual(em.typ, am.typ);
            }
        },
        .alias => |ed| {
            const ad = a.alias;
            if (!sameRef(ed.name, ad.name)) return error.AliasNameMismatch;
            try expectTypeEqual(ed.typ, ad.typ);
        },
        .const_assert => |ed| {
            const ad = a.const_assert;
            try expectExprEqual(ed.expr, ad.expr);
        },
    }
}

fn expectAttributesEqual(e: std.ArrayListUnmanaged(Ast.Attribute), a: std.ArrayListUnmanaged(Ast.Attribute)) Err!void {
    if (e.items.len != a.items.len) return error.AttributesLenMismatch;
    for (e.items, a.items) |ea, aa| {
        if (!std.mem.eql(u8, ea.name, aa.name)) return error.AttrNameMismatch;
        if (ea.loc != aa.loc) return error.AttrLocMismatch;
        if (ea.span.start != aa.span.start or ea.span.end != aa.span.end) {
            std.debug.print("attr span mismatch (@{s}): {d}..{d} vs {d}..{d}\n", .{ ea.name, ea.span.start, ea.span.end, aa.span.start, aa.span.end });
            return error.AttrSpanMismatch;
        }
        if (ea.args.items.len != aa.args.items.len) return error.AttrArgCountMismatch;
        for (ea.args.items, aa.args.items) |ex, ax| try expectExprEqual(ex, ax);
    }
}

fn expectOptTypeEqual(e: ?Ast.Type, a: ?Ast.Type) Err!void {
    if ((e == null) != (a == null)) return error.OptTypePresenceMismatch;
    if (e) |et| try expectTypeEqual(et, a.?);
}

fn expectTypeEqual(e: Ast.Type, a: Ast.Type) Err!void {
    if (@intFromEnum(std.meta.activeTag(e)) != @intFromEnum(std.meta.activeTag(a))) {
        std.debug.print("type tag mismatch: {s} vs {s}\n", .{ @tagName(std.meta.activeTag(e)), @tagName(std.meta.activeTag(a)) });
        return error.TypeTagMismatch;
    }
    if (e.span().start != a.span().start or e.span().end != a.span().end) {
        std.debug.print("type span mismatch ({s}): {d}..{d} vs {d}..{d}\n", .{ @tagName(std.meta.activeTag(e)), e.span().start, e.span().end, a.span().start, a.span().end });
        return error.TypeSpanMismatch;
    }
    switch (e) {
        .ident => |et| {
            const at = a.ident;
            if (!std.mem.eql(u8, et.name, at.name)) return error.IdentTypeNameMismatch;
            if (!sameRef(et.ref, at.ref)) return error.IdentTypeRefMismatch;
            if (et.loc != at.loc) return error.IdentTypeLocMismatch;
        },
        .vec => |et| {
            const at = a.vec;
            if (et.size != at.size) return error.VecSizeMismatch;
            if (et.loc != at.loc) return error.VecLocMismatch;
            try expectOptTypeEqual(et.elem_type, at.elem_type);
        },
        .mat => |et| {
            const at = a.mat;
            if (et.cols != at.cols or et.rows != at.rows) return error.MatShapeMismatch;
            if (et.loc != at.loc) return error.MatLocMismatch;
            try expectOptTypeEqual(et.elem_type, at.elem_type);
        },
        .array => |et| {
            const at = a.array;
            try expectOptTypeEqual(et.elem_type, at.elem_type);
            try expectOptExprEqual(et.size, at.size);
        },
        .ptr => |et| {
            const at = a.ptr;
            if (et.address_space != at.address_space) return error.PtrAddrMismatch;
            if (et.access_mode != at.access_mode) return error.PtrAccessMismatch;
            try expectTypeEqual(et.elem_type, at.elem_type);
        },
        .atomic => |et| {
            const at = a.atomic;
            if (et.loc != at.loc) return error.AtomicLocMismatch;
            try expectTypeEqual(et.elem_type, at.elem_type);
        },
        .sampler => |et| {
            const at = a.sampler;
            if (et.comparison != at.comparison) return error.SamplerCompMismatch;
        },
        .texture => |et| {
            const at = a.texture;
            if (et.kind != at.kind) return error.TextureKindMismatch;
            if (et.dimension != at.dimension) return error.TextureDimMismatch;
            if (et.access_mode != at.access_mode) return error.TextureAccessMismatch;
            if (!std.mem.eql(u8, et.texel_format, at.texel_format)) return error.TextureFormatMismatch;
            try expectOptTypeEqual(et.sampled_type, at.sampled_type);
        },
    }
}

fn expectOptExprEqual(e: ?Ast.Expr, a: ?Ast.Expr) Err!void {
    if ((e == null) != (a == null)) return error.OptExprPresenceMismatch;
    if (e) |et| try expectExprEqual(et, a.?);
}

fn expectExprEqual(e: Ast.Expr, a: Ast.Expr) Err!void {
    if (@intFromEnum(std.meta.activeTag(e)) != @intFromEnum(std.meta.activeTag(a))) {
        std.debug.print("expr tag mismatch: {s} vs {s}\n", .{ @tagName(std.meta.activeTag(e)), @tagName(std.meta.activeTag(a)) });
        return error.ExprTagMismatch;
    }
    if (e.span().start != a.span().start or e.span().end != a.span().end) {
        std.debug.print("expr span mismatch ({s}): {d}..{d} vs {d}..{d}\n", .{ @tagName(std.meta.activeTag(e)), e.span().start, e.span().end, a.span().start, a.span().end });
        return error.ExprSpanMismatch;
    }
    switch (e) {
        .ident => |ex| {
            const ax = a.ident;
            if (!std.mem.eql(u8, ex.name, ax.name)) return error.IdentExprNameMismatch;
            if (!sameRef(ex.ref, ax.ref)) return error.IdentExprRefMismatch;
            if (ex.loc != ax.loc) return error.IdentExprLocMismatch;
            if (@as(u8, @bitCast(ex.flags)) != @as(u8, @bitCast(ax.flags))) return error.IdentExprFlagsMismatch;
        },
        .literal => |ex| {
            const ax = a.literal;
            if (ex.kind != ax.kind) return error.LiteralKindMismatch;
            if (!std.mem.eql(u8, ex.value, ax.value)) return error.LiteralValueMismatch;
            if (ex.loc != ax.loc) return error.LiteralLocMismatch;
            if (@as(u8, @bitCast(ex.flags)) != @as(u8, @bitCast(ax.flags))) return error.LiteralFlagsMismatch;
        },
        .binary => |ex| {
            const ax = a.binary;
            if (ex.op != ax.op) return error.BinaryOpMismatch;
            if (ex.loc != ax.loc) return error.BinaryLocMismatch;
            if (@as(u8, @bitCast(ex.flags)) != @as(u8, @bitCast(ax.flags))) return error.BinaryFlagsMismatch;
            try expectExprEqual(ex.left, ax.left);
            try expectExprEqual(ex.right, ax.right);
        },
        .unary => |ex| {
            const ax = a.unary;
            if (ex.op != ax.op) return error.UnaryOpMismatch;
            if (ex.loc != ax.loc) return error.UnaryLocMismatch;
            if (@as(u8, @bitCast(ex.flags)) != @as(u8, @bitCast(ax.flags))) return error.UnaryFlagsMismatch;
            try expectExprEqual(ex.operand, ax.operand);
        },
        .call => |ex| {
            const ax = a.call;
            if (ex.loc != ax.loc) return error.CallLocMismatch;
            if (ex.end_loc != ax.end_loc) return error.CallEndLocMismatch;
            try expectOptExprEqual(ex.func, ax.func);
            try expectOptTypeEqual(ex.template_type, ax.template_type);
            if (ex.args.items.len != ax.args.items.len) return error.CallArgCountMismatch;
            for (ex.args.items, ax.args.items) |earg, aarg| try expectExprEqual(earg, aarg);
        },
        .index => |ex| {
            const ax = a.index;
            if (ex.loc != ax.loc or ex.end_loc != ax.end_loc) return error.IndexLocMismatch;
            try expectExprEqual(ex.base, ax.base);
            try expectExprEqual(ex.idx, ax.idx);
        },
        .member => |ex| {
            const ax = a.member;
            if (ex.loc != ax.loc) return error.MemberLocMismatch;
            if (!std.mem.eql(u8, ex.member_name, ax.member_name)) return error.MemberNameMismatch;
            try expectExprEqual(ex.base, ax.base);
        },
        .paren => |ex| {
            const ax = a.paren;
            try expectExprEqual(ex.expr, ax.expr);
        },
    }
}

fn expectOptCompoundEqual(e: ?*Ast.CompoundStmt, a: ?*Ast.CompoundStmt) Err!void {
    if ((e == null) != (a == null)) return error.OptCompoundPresenceMismatch;
    if (e) |ec| try expectCompoundEqual(ec, a.?);
}

fn expectCompoundEqual(e: *Ast.CompoundStmt, a: *Ast.CompoundStmt) Err!void {
    if (e.span.start != a.span.start or e.span.end != a.span.end) return error.CompoundSpanMismatch;
    if (e.stmts.items.len != a.stmts.items.len) {
        std.debug.print("compound stmt count mismatch: {d} vs {d}\n", .{ e.stmts.items.len, a.stmts.items.len });
        return error.CompoundLenMismatch;
    }
    for (e.stmts.items, a.stmts.items) |es, as_| try expectStmtEqual(es, as_);
}

fn expectStmtEqual(e: Ast.Stmt, a: Ast.Stmt) Err!void {
    if (@intFromEnum(std.meta.activeTag(e)) != @intFromEnum(std.meta.activeTag(a))) {
        std.debug.print("stmt tag mismatch: {s} vs {s}\n", .{ @tagName(std.meta.activeTag(e)), @tagName(std.meta.activeTag(a)) });
        return error.StmtTagMismatch;
    }
    if (e.span().start != a.span().start or e.span().end != a.span().end) {
        std.debug.print("stmt span mismatch: {d}..{d} vs {d}..{d}\n", .{ e.span().start, e.span().end, a.span().start, a.span().end });
        return error.StmtSpanMismatch;
    }
    switch (e) {
        .compound => |ec| try expectCompoundEqual(ec, a.compound),
        .@"return" => |es| {
            const as_ = a.@"return";
            if (es.loc != as_.loc) return error.ReturnLocMismatch;
            try expectOptExprEqual(es.value, as_.value);
        },
        .@"if" => |es| {
            const as_ = a.@"if";
            try expectExprEqual(es.condition, as_.condition);
            try expectCompoundEqual(es.body, as_.body);
            if ((es.else_branch == null) != (as_.else_branch == null)) return error.ElseBranchMismatch;
            if (es.else_branch) |eb| try expectStmtEqual(eb, as_.else_branch.?);
        },
        .@"switch" => |es| {
            const as_ = a.@"switch";
            try expectExprEqual(es.expr, as_.expr);
            if (es.cases.items.len != as_.cases.items.len) return error.SwitchCaseCountMismatch;
            for (es.cases.items, as_.cases.items) |ec, ac| {
                if (ec.selectors.items.len != ac.selectors.items.len) return error.SwitchSelectorCountMismatch;
                for (ec.selectors.items, ac.selectors.items) |esel, asel| try expectExprEqual(esel, asel);
                try expectCompoundEqual(ec.body, ac.body);
            }
        },
        .@"for" => |es| {
            const as_ = a.@"for";
            if ((es.init_stmt == null) != (as_.init_stmt == null)) return error.ForInitPresenceMismatch;
            if (es.init_stmt) |is_| try expectStmtEqual(is_, as_.init_stmt.?);
            try expectOptExprEqual(es.condition, as_.condition);
            if ((es.update == null) != (as_.update == null)) return error.ForUpdatePresenceMismatch;
            if (es.update) |u| try expectStmtEqual(u, as_.update.?);
            try expectCompoundEqual(es.body, as_.body);
        },
        .@"while" => |es| {
            const as_ = a.@"while";
            try expectExprEqual(es.condition, as_.condition);
            try expectCompoundEqual(es.body, as_.body);
        },
        .loop => |es| {
            const as_ = a.loop;
            try expectCompoundEqual(es.body, as_.body);
            if ((es.continuing == null) != (as_.continuing == null)) return error.LoopContPresenceMismatch;
            if (es.continuing) |c| try expectCompoundEqual(c, as_.continuing.?);
        },
        .@"break" => |es| {
            if (es.loc != a.@"break".loc) return error.BreakLocMismatch;
        },
        .break_if => |es| {
            try expectExprEqual(es.condition, a.break_if.condition);
        },
        .@"continue" => |es| {
            if (es.loc != a.@"continue".loc) return error.ContinueLocMismatch;
        },
        .discard => |es| {
            if (es.loc != a.discard.loc) return error.DiscardLocMismatch;
        },
        .assign => |es| {
            const as_ = a.assign;
            if (es.op != as_.op) return error.AssignOpMismatch;
            if (es.loc != as_.loc) return error.AssignLocMismatch;
            try expectExprEqual(es.left, as_.left);
            try expectExprEqual(es.right, as_.right);
        },
        .phony => |es| {
            const as_ = a.phony;
            if (es.loc != as_.loc) return error.PhonyLocMismatch;
            try expectExprEqual(es.expr, as_.expr);
        },
        .incr_decr => |es| {
            const as_ = a.incr_decr;
            if (es.increment != as_.increment) return error.IncrDecrOpMismatch;
            if (es.loc != as_.loc) return error.IncrDecrLocMismatch;
            try expectExprEqual(es.expr, as_.expr);
        },
        .call => |es| {
            try expectExprEqual(.{ .call = es.call }, .{ .call = a.call.call });
        },
        .decl => |es| {
            try expectDeclEqual(es.decl, a.decl.decl);
        },
    }
}
