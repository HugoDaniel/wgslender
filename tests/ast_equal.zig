//! Deep structural equality helpers for `Ast.Module`.
//!
//! Used by `tests/cst_lower_test.zig` to prove `CstLower.lowerTree` produces
//! a module with identical shape, symbols, scopes, decl/stmt/expr/type trees,
//! and `use_count` parity compared to `Parser.parse`. Error lists are NOT
//! compared — CstLower consumes a clean tree and doesn't replay Parser's
//! error-recovery diagnostics.

const std = @import("std");
const wgslender = @import("wgslender");
const Ast = wgslender.Ast;

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
    SymbolSlotMismatch,
    SymbolUseCountMismatch,
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
    IncrDecrOpMismatch,
    IncrDecrLocMismatch,
    TestExpectedEqual,
} || std.mem.Allocator.Error;

pub fn expectModulesEqual(expected: *const Ast.Module, actual: *const Ast.Module) Err!void {
    // Source pointer equality is not required; the slices usually do match
    // but the invariant is only content equality.
    try std.testing.expectEqualStrings(expected.source, actual.source);

    // Symbols: length + each slot.
    if (expected.symbols.items.len != actual.symbols.items.len) {
        std.debug.print(
            "symbols.len mismatch: expected {d}, actual {d}\n",
            .{ expected.symbols.items.len, actual.symbols.items.len },
        );
        return error.SymbolsLenMismatch;
    }
    for (expected.symbols.items, actual.symbols.items, 0..) |e, a, i| {
        try expectSymbolEqual(e, a, i);
    }

    // Directives.
    if (expected.directives.items.len != actual.directives.items.len) return error.DirectivesLenMismatch;
    for (expected.directives.items, actual.directives.items) |e, a| {
        try expectDirectiveEqual(e, a);
    }

    // Declarations.
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

    // Scope tree (structural: kind, sibling_index, member key set, children).
    try expectScopeEqual(expected.scope, actual.scope);
}

fn expectSymbolEqual(e: Ast.Symbol, a: Ast.Symbol, i: usize) Err!void {
    if (!std.mem.eql(u8, e.original_name, a.original_name)) {
        std.debug.print("symbol[{d}].original_name mismatch: '{s}' vs '{s}'\n", .{ i, e.original_name, a.original_name });
        return error.SymbolNameMismatch;
    }
    if (e.kind != a.kind) {
        std.debug.print("symbol[{d}] '{s}' .kind mismatch: {s} vs {s}\n", .{ i, e.original_name, @tagName(e.kind), @tagName(a.kind) });
        return error.SymbolKindMismatch;
    }
    if (@as(u16, @bitCast(e.flags)) != @as(u16, @bitCast(a.flags))) {
        std.debug.print("symbol[{d}] '{s}' .flags mismatch\n", .{ i, e.original_name });
        return error.SymbolFlagsMismatch;
    }
    if (e.nested_scope_slot != a.nested_scope_slot) return error.SymbolSlotMismatch;
    if (e.use_count != a.use_count) {
        std.debug.print("symbol[{d}] '{s}' .use_count mismatch: {d} vs {d}\n", .{ i, e.original_name, e.use_count, a.use_count });
        return error.SymbolUseCountMismatch;
    }
    if (e.loc != a.loc) {
        std.debug.print("symbol[{d}] '{s}' .loc mismatch: {d} vs {d}\n", .{ i, e.original_name, e.loc, a.loc });
        return error.SymbolLocMismatch;
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
        if (am.ref != entry.value_ptr.ref) return error.ScopeMemberRefMismatch;
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
            if (ed.name != ad.name) return error.DeclNameMismatch;
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .override => |ed| {
            const ad = a.override;
            if (ed.name != ad.name) return error.DeclNameMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .@"var" => |ed| {
            const ad = a.@"var";
            if (ed.name != ad.name) return error.DeclNameMismatch;
            if (ed.address_space != ad.address_space) return error.VarAddrSpaceMismatch;
            if (ed.access_mode != ad.access_mode) return error.VarAccessModeMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .let => |ed| {
            const ad = a.let;
            if (ed.name != ad.name) return error.DeclNameMismatch;
            try expectOptTypeEqual(ed.typ, ad.typ);
            try expectOptExprEqual(ed.initializer, ad.initializer);
        },
        .function => |ed| {
            const ad = a.function;
            if (ed.name != ad.name) return error.FuncNameMismatch;
            try expectAttributesEqual(ed.attributes, ad.attributes);
            try expectAttributesEqual(ed.return_attr, ad.return_attr);
            if (ed.parameters.items.len != ad.parameters.items.len) return error.FuncParamCountMismatch;
            for (ed.parameters.items, ad.parameters.items) |ep, ap| {
                if (ep.name != ap.name) return error.ParamNameMismatch;
                try expectAttributesEqual(ep.attributes, ap.attributes);
                try expectTypeEqual(ep.typ, ap.typ);
            }
            try expectOptTypeEqual(ed.return_type, ad.return_type);
            try expectOptCompoundEqual(ed.body, ad.body);
        },
        .@"struct" => |ed| {
            const ad = a.@"struct";
            if (ed.name != ad.name) return error.StructNameMismatch;
            if (ed.members.items.len != ad.members.items.len) return error.StructMemberCountMismatch;
            for (ed.members.items, ad.members.items) |em, am| {
                if (em.name != am.name) return error.StructMemberNameMismatch;
                try expectAttributesEqual(em.attributes, am.attributes);
                try expectTypeEqual(em.typ, am.typ);
            }
        },
        .alias => |ed| {
            const ad = a.alias;
            if (ed.name != ad.name) return error.AliasNameMismatch;
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
    if (e.span().start != a.span().start or e.span().end != a.span().end) return error.TypeSpanMismatch;
    switch (e) {
        .ident => |et| {
            const at = a.ident;
            if (!std.mem.eql(u8, et.name, at.name)) return error.IdentTypeNameMismatch;
            if (et.ref != at.ref) return error.IdentTypeRefMismatch;
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
    switch (e) {
        .ident => |ex| {
            const ax = a.ident;
            if (!std.mem.eql(u8, ex.name, ax.name)) return error.IdentExprNameMismatch;
            if (ex.ref != ax.ref) return error.IdentExprRefMismatch;
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
