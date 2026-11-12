//! Non-zero-delta trivia shortcut tests (Task B).
//!
//! `Incremental.reparse` must reuse the previous module + CST for any edit
//! confined to a single inter-real-token trivia gap — including edits with
//! a non-zero byte delta (comment insert/delete, whitespace growth) — as
//! long as the real-token ordinal stream, tags, lengths, byte text, and
//! per-token coordinates satisfy the gate in `incremental/Anchor.zig`.
//!
//! Every oracle here is a fresh `Incremental.parseFull` of the same source:
//! after any trivia edit the CST, AST spans, symbol table, scope-member
//! locations, and parse errors must be byte-identical to that oracle, while
//! the symbol table must NOT grow (no tombstones) and the module pointer
//! must be preserved.
//!
//! Failure symptoms at the pre-B tip (71aa102) these tests pin:
//!   - a comment keystroke takes the compound splice: symbols grow by one
//!     tombstone per local, `is_retired` entries appear;
//!   - leading / trailing / comment-only edits fall back to parseFull
//!     (`reused == false`, fresh module pointer);
//!   - zero-delta whitespace redistribution reuses stale CST offsets;
//!   - zero-delta trivia does not count toward HOT_EDIT_COALESCE_MAX.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Cst = wgslender.Cst;
const Incremental = wgslender.Incremental;
const Parser = wgslender.Parser;

const gpa = std.testing.allocator;

fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

// =========================================================================
// Oracle helpers
// =========================================================================

fn countRetired(module: *const Ast.Module) usize {
    var n: usize = 0;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_retired) n += 1;
    }
    return n;
}

/// Strict per-index symbol-table comparison: same count, same names/kinds/
/// flags/locations. The trivia path must never append or reorder symbols,
/// so the oracle's index assignment is exactly comparable.
fn expectSymbolsMatch(got: *const Ast.Module, oracle: *const Ast.Module) !void {
    if (got.symbols.items.len != oracle.symbols.items.len) {
        std.debug.print("symbol count mismatch: got={d} oracle={d}\n", .{
            got.symbols.items.len, oracle.symbols.items.len,
        });
        return error.SymbolCountMismatch;
    }
    for (got.symbols.items, oracle.symbols.items, 0..) |g, o, i| {
        if (!std.mem.eql(u8, g.original_name, o.original_name) or
            g.kind != o.kind or g.flags.is_retired != o.flags.is_retired or
            g.loc != o.loc)
        {
            std.debug.print(
                "symbol[{d}] mismatch: got='{s}' kind={s} retired={} loc={d} oracle='{s}' kind={s} retired={} loc={d}\n",
                .{ i, g.original_name, @tagName(g.kind), g.flags.is_retired, g.loc, o.original_name, @tagName(o.kind), o.flags.is_retired, o.loc },
            );
            return error.SymbolMismatch;
        }
    }
    const got_uc = got.use_counts.counts;
    const oracle_uc = oracle.use_counts.counts;
    if (got_uc.len != oracle_uc.len or !std.mem.eql(u32, got_uc, oracle_uc)) {
        std.debug.print("use_count table mismatch (got len={d} oracle len={d})\n", .{ got_uc.len, oracle_uc.len });
        return error.UseCountMismatch;
    }
}

fn expectErrorsMatch(got: []const Parser.ParseError, oracle: []const Parser.ParseError) !void {
    if (got.len != oracle.len) {
        std.debug.print("error count mismatch: got={d} oracle={d}\n", .{ got.len, oracle.len });
        for (got) |e| std.debug.print("  got    {s} pos={d} end={d}\n", .{ e.code, e.pos, e.end });
        for (oracle) |e| std.debug.print("  oracle {s} pos={d} end={d}\n", .{ e.code, e.pos, e.end });
        return error.ErrorCountMismatch;
    }
    for (got, oracle) |g, o| {
        try std.testing.expectEqualStrings(o.code, g.code);
        try std.testing.expectEqual(o.pos, g.pos);
        try std.testing.expectEqual(o.end, g.end);
    }
}

/// Lossless-CST check: concatenating every leaf token in tree order
/// reproduces `tree.source` exactly.
fn expectLossless(tree: *const Cst.Tree) !void {
    var concat: std.ArrayList(u8) = .empty;
    defer concat.deinit(gpa);
    var it = tree.rootCursor().tokens();
    while (it.next()) |tok_idx| {
        const s = tree.tokens.items(.start)[tok_idx];
        const e = tree.tokens.items(.end)[tok_idx];
        try concat.appendSlice(gpa, tree.source[s..e]);
    }
    try std.testing.expectEqualStrings(tree.source, concat.items);
}

/// Full structural CST comparison against a fresh-parse oracle: token
/// tags/starts/ends, node kinds/starts/ends/parents/child counts, child
/// table entries (node vs token + index), and error entries.
fn expectCstMatchesOracle(got: *const Cst.Tree, oracle: *const Cst.Tree) !void {
    try expectLossless(got);

    if (got.tokens.len != oracle.tokens.len) {
        std.debug.print("token count mismatch: got={d} oracle={d}\n", .{ got.tokens.len, oracle.tokens.len });
        return error.CstTokenCountMismatch;
    }
    {
        const gt = got.tokens.items(.tag);
        const ot = oracle.tokens.items(.tag);
        const gs = got.tokens.items(.start);
        const os = oracle.tokens.items(.start);
        const ge = got.tokens.items(.end);
        const oe = oracle.tokens.items(.end);
        for (0..got.tokens.len) |i| {
            if (gt[i] != ot[i] or gs[i] != os[i] or ge[i] != oe[i]) {
                std.debug.print("token[{d}] mismatch: got {s}[{d},{d}) oracle {s}[{d},{d})\n", .{
                    i, @tagName(gt[i]), gs[i], ge[i], @tagName(ot[i]), os[i], oe[i],
                });
                return error.CstTokenMismatch;
            }
        }
    }

    if (got.nodes.len != oracle.nodes.len) {
        std.debug.print("node count mismatch: got={d} oracle={d}\n", .{ got.nodes.len, oracle.nodes.len });
        return error.CstNodeCountMismatch;
    }
    for (0..got.nodes.len) |i| {
        const g = got.getNode(@enumFromInt(@as(u32, @intCast(i))));
        const o = oracle.getNode(@enumFromInt(@as(u32, @intCast(i))));
        if (g.kind != o.kind or g.start != o.start or g.end != o.end or
            g.parent != o.parent or g.first_child != o.first_child or g.child_count != o.child_count)
        {
            std.debug.print(
                "node[{d}] mismatch: got kind={s} [{d},{d}) p={d} fc={d} cc={d} | oracle kind={s} [{d},{d}) p={d} fc={d} cc={d}\n",
                .{ i, @tagName(g.kind), g.start, g.end, g.parent.raw(), g.first_child, g.child_count, @tagName(o.kind), o.start, o.end, o.parent.raw(), o.first_child, o.child_count },
            );
            return error.CstNodeMismatch;
        }
    }

    if (got.children.len != oracle.children.len) {
        std.debug.print("children count mismatch: got={d} oracle={d}\n", .{ got.children.len, oracle.children.len });
        return error.CstChildrenCountMismatch;
    }
    for (got.children, oracle.children, 0..) |gc, oc, i| {
        if (gc.is_token != oc.is_token or gc.index != oc.index) {
            std.debug.print("children[{d}] mismatch: got tok={} idx={d} oracle tok={} idx={d}\n", .{ i, gc.is_token, gc.index, oc.is_token, oc.index });
            return error.CstChildMismatch;
        }
    }

    if (got.errors.len != oracle.errors.len) {
        std.debug.print("cst errors count mismatch: got={d} oracle={d}\n", .{ got.errors.len, oracle.errors.len });
        return error.CstErrorCountMismatch;
    }
    for (got.errors, oracle.errors, 0..) |ge, oe, i| {
        if (ge.node != oe.node or !std.mem.eql(u8, ge.message, oe.message)) {
            std.debug.print("cst error[{d}] mismatch\n", .{i});
            return error.CstErrorMismatch;
        }
    }
}

// =========================================================================
// AST fingerprint oracle
//
// A recursive dump of every span/loc field plus the symbol table, use
// counts, and scope-tree member locations. Two modules produce identical
// fingerprints iff their coordinate-bearing state matches.
// =========================================================================

const Fp = struct {
    out: std.ArrayList(u8) = .empty,

    fn p(self: *Fp, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(gpa, fmt, args);
        defer gpa.free(s);
        try self.out.appendSlice(gpa, s);
    }

    fn node(self: *Fp, prefix: []const u8, n: anytype) !void {
        const T = @TypeOf(n.*);
        try self.p("{s}", .{prefix});
        if (@hasField(T, "span")) try self.p(" s{d}e{d}", .{ n.span.start, n.span.end });
        if (@hasField(T, "loc")) try self.p(" l{d}", .{n.loc});
        if (@hasField(T, "end_loc")) try self.p(" L{d}", .{n.end_loc});
        try self.p("\n", .{});
    }

    fn attrs(self: *Fp, list: []const Ast.Attribute) !void {
        for (list) |*a| {
            try self.p("attr {s}", .{a.name});
            if (@hasField(Ast.Attribute, "span")) try self.p(" s{d}e{d}", .{ a.span.start, a.span.end });
            if (@hasField(Ast.Attribute, "loc")) try self.p(" l{d}", .{a.loc});
            try self.p("\n", .{});
            for (a.args.items) |e| try self.expr(e);
        }
    }

    fn typ(self: *Fp, t: Ast.Type) error{OutOfMemory}!void {
        switch (t) {
            .ident => |id| try self.node("ident_t", id),
            .sampler => |sm| try self.node("sampler_t", sm),
            .vec => |v| {
                try self.node("vec_t", v);
                if (v.elem_type) |et| try self.typ(et);
            },
            .mat => |m| {
                try self.node("mat_t", m);
                if (m.elem_type) |et| try self.typ(et);
            },
            .array => |a| {
                try self.node("array_t", a);
                if (a.elem_type) |et| try self.typ(et);
                if (a.size) |e| try self.expr(e);
            },
            .ptr => |pt| {
                try self.node("ptr_t", pt);
                try self.typ(pt.elem_type);
            },
            .atomic => |a| {
                try self.node("atomic_t", a);
                try self.typ(a.elem_type);
            },
            .texture => |tex| {
                try self.node("texture_t", tex);
                if (tex.sampled_type) |st| try self.typ(st);
            },
        }
    }

    fn expr(self: *Fp, e: Ast.Expr) error{OutOfMemory}!void {
        switch (e) {
            inline else => |ptr| {
                try self.node(@tagName(e), ptr);
                switch (e) {
                    .paren => |p_| try self.expr(p_.expr),
                    .binary => |b| {
                        try self.expr(b.left);
                        try self.expr(b.right);
                    },
                    .unary => |u| try self.expr(u.operand),
                    .call => |c| {
                        if (c.func) |f| try self.expr(f);
                        if (c.template_type) |t| try self.typ(t);
                        for (c.args.items) |a| try self.expr(a);
                    },
                    .index => |ix| {
                        try self.expr(ix.base);
                        try self.expr(ix.idx);
                    },
                    .member => |m| try self.expr(m.base),
                    .literal, .ident => {},
                }
            },
        }
    }

    fn compound(self: *Fp, c: *const Ast.CompoundStmt) error{OutOfMemory}!void {
        try self.node("compound", c);
        for (c.stmts.items) |*s| try self.stmt(s);
    }

    fn stmt(self: *Fp, s: *const Ast.Stmt) error{OutOfMemory}!void {
        switch (s.*) {
            .compound => |c| try self.compound(c),
            .@"return" => |r| {
                try self.node("return", r);
                if (r.value) |v| try self.expr(v);
            },
            .@"if" => |i| {
                try self.node("if", i);
                try self.expr(i.condition);
                try self.compound(i.body);
                if (i.else_branch != null) try self.stmt(&i.else_branch.?);
            },
            .@"switch" => |sw| {
                try self.node("switch", sw);
                try self.expr(sw.expr);
                for (sw.cases.items) |*c| {
                    try self.p("case default={}\n", .{c.has_default});
                    for (c.selectors.items) |sel| try self.expr(sel);
                    try self.compound(c.body);
                }
            },
            .@"for" => |f| {
                try self.node("for", f);
                if (f.init_stmt != null) try self.stmt(&f.init_stmt.?);
                if (f.condition) |c| try self.expr(c);
                if (f.update != null) try self.stmt(&f.update.?);
                try self.compound(f.body);
            },
            .@"while" => |w| {
                try self.node("while", w);
                try self.expr(w.condition);
                try self.compound(w.body);
            },
            .loop => |l| {
                try self.node("loop", l);
                try self.compound(l.body);
                if (l.continuing) |c| try self.compound(c);
            },
            .break_if => |b| {
                try self.node("break_if", b);
                try self.expr(b.condition);
            },
            .assign => |a| {
                try self.node("assign", a);
                try self.expr(a.left);
                try self.expr(a.right);
            },
            .phony => |ph| {
                try self.node("phony", ph);
                try self.expr(ph.expr);
            },
            .incr_decr => |inc| {
                try self.node("incr_decr", inc);
                try self.expr(inc.expr);
            },
            .call => |cs| {
                try self.node("call_stmt", cs);
                try self.expr(.{ .call = cs.call });
            },
            .decl => |d| {
                try self.node("decl_stmt", d);
                try self.declInner(d.decl);
            },
            .@"break" => |b| try self.node("break", b),
            .@"continue" => |c| try self.node("continue", c),
            .discard => |di| try self.node("discard", di),
        }
    }

    fn declInner(self: *Fp, d: Ast.Decl) error{OutOfMemory}!void {
        switch (d) {
            .@"const" => |c| {
                try self.node("const", c);
                if (c.typ) |t| try self.typ(t);
                if (c.initializer) |e| try self.expr(e);
            },
            .override => |o| {
                try self.node("override", o);
                try self.attrs(o.attributes.items);
                if (o.typ) |t| try self.typ(t);
                if (o.initializer) |e| try self.expr(e);
            },
            .@"var" => |v| {
                try self.node("var", v);
                try self.attrs(v.attributes.items);
                if (v.typ) |t| try self.typ(t);
                if (v.initializer) |e| try self.expr(e);
            },
            .let => |l| {
                try self.node("let", l);
                if (l.typ) |t| try self.typ(t);
                if (l.initializer) |e| try self.expr(e);
            },
            .function => |f| {
                try self.node("fn", f);
                try self.attrs(f.attributes.items);
                for (f.parameters.items) |*p_| {
                    try self.p("param\n", .{});
                    try self.attrs(p_.attributes.items);
                    try self.typ(p_.typ);
                }
                if (f.return_type) |t| try self.typ(t);
                try self.attrs(f.return_attr.items);
                if (f.body) |b| try self.compound(b);
            },
            .@"struct" => |s| {
                try self.node("struct", s);
                for (s.members.items) |*m| {
                    try self.p("member\n", .{});
                    try self.attrs(m.attributes.items);
                    try self.typ(m.typ);
                }
            },
            .alias => |a| {
                try self.node("alias", a);
                try self.typ(a.typ);
            },
            .const_assert => |ca| {
                try self.node("const_assert", ca);
                try self.expr(ca.expr);
            },
        }
    }
};

fn dumpScopeTree(module: *const Ast.Module, scope: *const Ast.Scope, fp: *Fp, depth: usize, strict: bool) error{OutOfMemory}!void {
    try fp.p("scope {s} si={d} depth={d}\n", .{ @tagName(scope.kind), scope.sibling_index, depth });
    var it = scope.members.iterator();
    while (it.next()) |e| {
        // Fallback results (anchor splices) legitimately carry tombstones
        // a fresh parse does not have: skip members resolving to retired
        // symbols and compare names/locations only — symbol indices shift
        // whenever tombstones precede fresh copies.
        if (!strict) {
            if (module.symbols.items[@intFromEnum(e.value_ptr.ref)].flags.is_retired) continue;
            try fp.p("sm {s} loc={d}\n", .{ e.key_ptr.*, e.value_ptr.loc });
        } else {
            try fp.p("sm {s} -> {d} loc={d}\n", .{ e.key_ptr.*, @intFromEnum(e.value_ptr.ref), e.value_ptr.loc });
        }
    }
    for (scope.children.items) |c| try dumpScopeTree(module, c, fp, depth + 1, strict);
}

fn moduleFingerprint(module: *const Ast.Module, strict: bool) ![]u8 {
    var fp = Fp{};
    errdefer fp.out.deinit(gpa);

    for (module.directives.items) |*dir| {
        switch (dir.*) {
            inline else => |*d| {
                try fp.p("dir {s}", .{@tagName(dir.*)});
                if (@hasField(@TypeOf(d.*), "span")) try fp.p(" s{d}e{d}", .{ d.span.start, d.span.end });
                try fp.p("\n", .{});
            },
        }
    }
    for (module.declarations.items) |d| try fp.declInner(d);
    for (module.symbols.items, 0..) |sym, i| {
        if (!strict and sym.flags.is_retired) continue;
        try fp.p("sym{d} {s} {s} l{d} r{}\n", .{ i, sym.original_name, @tagName(sym.kind), sym.loc, sym.flags.is_retired });
    }
    try fp.p("uc", .{});
    for (module.use_counts.counts, 0..) |c, i| {
        if (!strict and module.symbols.items[i].flags.is_retired) continue;
        try fp.p(" {d}", .{c});
    }
    try fp.p("\n", .{});
    try dumpScopeTree(module, module.scope, &fp, 0, strict);
    return fp.out.toOwnedSlice(gpa);
}

/// Full engine-level oracle: CST structure, AST fingerprint, symbol table,
/// and error list must all match a fresh parse of the same source.
///
/// Fingerprinting first applies `absorbInteriors` — the documented entry
/// contract of every external reader (Validator, LSP features, ...) — so
/// deferred `interior_pending` biases from non-owner decls are folded in.
/// For a `reused` result (trivia shortcut) the fingerprint is STRICT
/// (exact symbol indices, tombstones forbidden — the ruling forbids
/// retirement on this path); for a fallback result (anchor splice /
/// parseFull) tombstones are legal task-A state, so retired symbols and
/// their scope-member entries are skipped.
fn expectMatchesFreshParse(result: *const Incremental.ReparseResult) !void {
    var oracle = try Incremental.parseFull(gpa, result.source);
    defer oracle.deinit();

    try expectCstMatchesOracle(&result.cst, &oracle.cst);

    result.module.absorbInteriors();
    // Both fingerprints use the same strictness so the comparison is
    // apples-to-apples. Strict (exact symbol indices) exactly when no
    // tombstones are present: a fresh parse never has them, the trivia
    // shortcut must never create them (asserted separately), and anchor
    // splices legitimately may — indices shift past those tombstones, so
    // only active symbols and members are comparable there. `reused`
    // alone cannot discriminate: splices set it too.
    const strict = countRetired(result.module) == 0;
    const got_fp = try moduleFingerprint(result.module, strict);
    defer gpa.free(got_fp);
    const oracle_fp = try moduleFingerprint(oracle.module, strict);
    defer gpa.free(oracle_fp);
    if (!std.mem.eql(u8, got_fp, oracle_fp)) {
        // Print the first divergence for triage.
        var i: usize = 0;
        while (i < got_fp.len and i < oracle_fp.len and got_fp[i] == oracle_fp[i]) i += 1;
        const from = if (i > 60) i - 60 else 0;
        std.debug.print("fingerprint mismatch at byte {d}:\n  got:    {s}\n  oracle: {s}\n", .{
            i, got_fp[from..@min(got_fp.len, i + 120)], oracle_fp[from..@min(oracle_fp.len, i + 120)],
        });
        return error.FingerprintMismatch;
    }
    try expectErrorsMatch(result.errors, oracle.errors);
}

// =========================================================================
// T1 — non-zero trivia insert reuses the module without symbol churn.
// =========================================================================

test "non-zero trivia insert reuses the module without symbol churn" {
    const src: [:0]const u8 =
        \\fn f(p: i32) -> i32 {
        \\    let a: i32 = p;
        \\    let b: i32 = a + 1;
        \\    _ = b;
        \\    return b;
        \\}
    ;
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const module_before = state.module;
    const symbols_before = state.module.symbols.items.len;
    const version_before = state.module_version;

    // Insert a 7-byte comment between statements (delta = +7).
    const ins_at = at(src, "_ = b;");
    const next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "// note\n",
    });
    state.deinit();
    state = next;

    try std.testing.expect(state.reused);
    try std.testing.expectEqual(module_before, state.module);
    try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));
    // Non-zero delta bumps module_version (analysis caches invalidate).
    try std.testing.expectEqual(version_before +% 1, state.module_version);
    // Every trivia edit counts toward the coalescing watermark.
    try std.testing.expectEqual(@as(u16, 1), state.hot_edits_since_full);

    try expectMatchesFreshParse(&state);
    try std.testing.expect(std.mem.indexOf(u8, state.source, "// note") != null);
}

// =========================================================================
// T2 — comment insertion and deletion match the full-parse CST oracle
// (trivia token count changes across the edit).
// =========================================================================

test "comment insertion and deletion match the full-parse CST oracle" {
    const src: [:0]const u8 =
        \\struct S { m: i32 }
        \\fn g(s: S) -> i32 { return s.m; }
    ;
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Insert a block comment + extra whitespace inside the fn body.
    const ins_at = at(src, "return");
    var next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "/* gap */  ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try expectMatchesFreshParse(&state);

    // Replace it with a line comment (trivia token count changes again).
    const rep_start = ins_at;
    const rep_end = ins_at + @as(u32, "/* gap */  ".len);
    next = try Incremental.reparse(gpa, &state, .{
        .start = rep_start,
        .end = rep_end,
        .new_text = "// line\n  ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try expectMatchesFreshParse(&state);

    // Delete it entirely — back to the original bytes.
    const del_start = ins_at;
    const del_end = del_start + @as(u32, "// line\n  ".len);
    next = try Incremental.reparse(gpa, &state, .{
        .start = del_start,
        .end = del_end,
        .new_text = "",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try std.testing.expectEqualStrings(src, state.source);
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T3 — leading, trailing, and comment-only-document trivia gaps.
// =========================================================================

test "leading, trailing, and comment-only-document trivia gaps round-trip" {
    // Leading: insert a header comment at byte 0.
    {
        const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const module_before = state.module;

        const next = try Incremental.reparse(gpa, &state, .{ .start = 0, .end = 0, .new_text = "// hdr\n" });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try std.testing.expectEqual(module_before, state.module);
        try expectMatchesFreshParse(&state);
        try std.testing.expectEqualStrings("// hdr\nfn f() -> i32 { return 1; }", state.source);
    }
    // Trailing: append after the last decl, adjacent to EOF.
    {
        const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const module_before = state.module;

        const end: u32 = @intCast(src.len);
        const next = try Incremental.reparse(gpa, &state, .{ .start = end, .end = end, .new_text = "\n// tail" });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try std.testing.expectEqual(module_before, state.module);
        try expectMatchesFreshParse(&state);
    }
    // Trailing with existing trivia before EOF.
    {
        const src: [:0]const u8 = "const x = 1; // already\n";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();

        const end: u32 = @intCast(src.len);
        const next = try Incremental.reparse(gpa, &state, .{ .start = end, .end = end, .new_text = "// more\n" });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try expectMatchesFreshParse(&state);
    }
    // Comment-only document: grow the comment.
    {
        const src: [:0]const u8 = "// only\n";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const module_before = state.module;

        const ins_at: u32 = 3;
        const next = try Incremental.reparse(gpa, &state, .{ .start = ins_at, .end = ins_at, .new_text = "a " });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try std.testing.expectEqual(module_before, state.module);
        try expectMatchesFreshParse(&state);
        try std.testing.expectEqualStrings("// a only\n", state.source);
    }
    // Empty module: first content is a comment.
    {
        var state = try Incremental.parseFull(gpa, "");
        defer state.deinit();

        const next = try Incremental.reparse(gpa, &state, .{ .start = 0, .end = 0, .new_text = "// c" });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try expectMatchesFreshParse(&state);
        try std.testing.expectEqualStrings("// c", state.source);
    }
}

// =========================================================================
// T4 — AST and symbol locations match full parse after trivia shifts
// (directives, attributes, params, nested blocks, for-init, struct members).
// =========================================================================

test "AST and symbol locations match full parse after trivia shifts" {
    const src: [:0]const u8 =
        \\enable f16;
        \\struct Inner { x: i32, @size(4) y: i32 }
        \\fn pick(a: i32, b: i32) -> i32 {
        \\    var acc: i32 = 0;
        \\    for (var i: i32 = 0; i < b; i = i + 1) {
        \\        if (i > a) {
        \\            acc = acc + Inner(i).y;
        \\        } else {
        \\            acc = acc - 1;
        \\        }
        \\    }
        \\    while (acc > 100) { acc = acc - b; }
        \\    return acc;
        \\}
    ;

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // A sequence of trivia edits at structurally distinct positions.
    const edits = [_]struct { needle: []const u8, text: []const u8 }{
        .{ .needle = "enable", .text = "// lead\n" },
        .{ .needle = "struct Inner", .text = "  " },
        .{ .needle = "@size(4)", .text = " /*attr*/ " },
        .{ .needle = "var acc", .text = "\t" },
        .{ .needle = "if (i > a)", .text = "// cond\n" },
        .{ .needle = "acc = acc - 1;", .text = " " },
        .{ .needle = "while (acc", .text = "/* loop */ " },
        .{ .needle = "return acc;", .text = "  // out\n" },
    };
    for (edits) |e| {
        // The needle must still exist after prior edits.
        const pos = std.mem.indexOf(u8, state.source, e.needle) orelse return error.NeedleLost;
        const next = try Incremental.reparse(gpa, &state, .{
            .start = @intCast(pos),
            .end = @intCast(pos),
            .new_text = e.text,
        });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try expectMatchesFreshParse(&state);
    }
}

// =========================================================================
// T5 — insertion does not extend the preceding statement span.
// =========================================================================

test "insertion does not extend the preceding statement span" {
    const src: [:0]const u8 = "fn f() -> i32 { let q = 1; return q; }";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Top-level statement spans of the fn body, before the edit.
    const fn_decl = blk: {
        for (state.module.declarations.items) |d| {
            if (d == .function) break :blk d.function;
        }
        return error.NoFunction;
    };
    const body = fn_decl.body orelse return error.NoBody;
    try std.testing.expectEqual(@as(usize, 2), body.stmts.items.len);
    const first_before = body.stmts.items[0].span();
    const second_before = body.stmts.items[1].span();

    // Insert trivia exactly at the first statement's end / second's start.
    const next = try Incremental.reparse(gpa, &state, .{
        .start = first_before.end,
        .end = first_before.end,
        .new_text = " /*c*/ ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    const fn_after = blk: {
        for (state.module.declarations.items) |d| {
            if (d == .function) break :blk d.function;
        }
        return error.NoFunction;
    };
    const body_after = fn_after.body orelse return error.NoBody;
    const first_after = body_after.stmts.items[0].span();
    const second_after = body_after.stmts.items[1].span();

    // Preceding span keeps its end; following statement shifts by delta.
    try std.testing.expectEqual(first_before.end, first_after.end);
    try std.testing.expectEqual(first_before.start, first_after.start);
    const delta: i64 = @intCast(" /*c*/ ".len);
    try std.testing.expectEqual(
        @as(i64, second_before.start) + delta,
        @as(i64, second_after.start),
    );
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T6 — scope map survives trivia retokenization.
// =========================================================================

test "scope map survives trivia retokenization" {
    const src: [:0]const u8 =
        \\fn f() -> i32 {
        \\    let base: i32 = 1;
        \\    if (base > 0) {
        \\        let inner: i32 = 2;
        \\        return base + inner;
        \\    }
        \\    return base;
        \\}
    ;
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Locate the `if` body's compound_stmt node index (pre-order) and its
    // registered scope pointer before the edit.
    var compound_nodes: std.ArrayList(u32) = .empty;
    defer compound_nodes.deinit(gpa);
    for (0..state.cst.nodes.len) |i| {
        if (state.cst.nodes.items(.kind)[i] == .compound_stmt) {
            try compound_nodes.append(gpa, @intCast(i));
        }
    }
    try std.testing.expect(compound_nodes.items.len >= 2);
    const if_compound = compound_nodes.items[1];
    const scope_before = state.scope_for_cst_node.get(if_compound) orelse
        return error.NoScopeForCompound;

    // Non-zero trivia insert inside the function body.
    const ins_at = at(src, "let base");
    var next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "// c\n",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);

    // Node indices are preserved, so the same key resolves to the same
    // scope object — no rebuild, no byte shifting required.
    const scope_after = state.scope_for_cst_node.get(if_compound) orelse
        return error.ScopeMapLostEntry;
    try std.testing.expectEqual(scope_before, scope_after);

    // And a later semantic splice still resolves the right scope: flip a
    // literal inside the if-body and require the hot path to stay correct.
    const two_at = at(state.source, "let inner: i32 = 2;");
    next = try Incremental.reparse(gpa, &state, .{
        .start = two_at + @as(u32, "let inner: i32 = ".len),
        .end = two_at + @as(u32, "let inner: i32 = ".len) + 1,
        .new_text = "5",
    });
    state.deinit();
    state = next;
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T7 — token-adjacent boundaries: splitting a real token is semantic.
// =========================================================================

test "1.0 cannot be split by the trivia shortcut" {
    const src: [:0]const u8 = "fn f() -> f32 { let v = 1.0; return v; }";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const lit = at(src, "1.0");
    const next = try Incremental.reparse(gpa, &state, .{
        .start = lit,
        .end = lit + 3,
        .new_text = "1 . 0",
    });
    state.deinit();
    state = next;

    // Whatever path it takes, the result must equal a fresh parse.
    try expectMatchesFreshParse(&state);
    try std.testing.expectEqualStrings("fn f() -> f32 { let v = 1 . 0; return v; }", state.source);
}

// =========================================================================
// T8 — identifier / compound-operator / comment-delimiter boundaries.
// =========================================================================

test "identifier, compound-operator, and comment-delimiter boundaries reject the shortcut" {
    // Identifier split inside a function body: `acc` → `ac c`.
    {
        const src: [:0]const u8 = "fn f() -> i32 { let acc: i32 = 1; return acc; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const use = at(src, "return acc") + @as(u32, "return ".len);
        const next = try Incremental.reparse(gpa, &state, .{
            .start = use + 2,
            .end = use + 3,
            .new_text = " c",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }
    // Compound operator split: `>>=` stays one token; splitting is semantic.
    {
        const src: [:0]const u8 = "fn f(x: u32) -> u32 { x >>= 1u; return x; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const op = at(src, ">>=");
        const next = try Incremental.reparse(gpa, &state, .{
            .start = op + 1,
            .end = op + 1,
            .new_text = " ",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }
    // A single `/` insert is a real token until a second `/` makes trivia.
    {
        const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const ret = at(src, "return 1;");
        var next = try Incremental.reparse(gpa, &state, .{
            .start = ret,
            .end = ret,
            .new_text = "/",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
        // Second `/`: now `//` swallows the rest of the line — the real
        // token stream differs from the previous state, still semantic.
        next = try Incremental.reparse(gpa, &state, .{
            .start = ret,
            .end = ret + 1,
            .new_text = "//",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }
    // Inserting a whole `//` comment in one edit IS trivia — the shortcut
    // must fire because the complete real-token sequence is unchanged.
    {
        const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const ret = at(src, "return 1;");
        const symbols_before = state.module.symbols.items.len;
        const next = try Incremental.reparse(gpa, &state, .{
            .start = ret,
            .end = ret,
            .new_text = "// c\n",
        });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
        try expectMatchesFreshParse(&state);
    }
    // Nested block comments: editing inside `/* /* * / */` stays trivia.
    {
        const src: [:0]const u8 = "/* outer /* inner */ still outer */ fn f() {}";
        var state = try Incremental.parseFull(gpa, src);
        defer state.deinit();
        const inner = at(src, "inner");
        const symbols_before = state.module.symbols.items.len;
        const next = try Incremental.reparse(gpa, &state, .{
            .start = inner,
            .end = inner + @as(u32, "inner".len),
            .new_text = "nested",
        });
        state.deinit();
        state = next;
        try std.testing.expect(state.reused);
        try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
        try expectMatchesFreshParse(&state);
    }
}

// =========================================================================
// T9 — whole-range zero-delta whitespace redistribution cannot reuse
// stale offsets.
// =========================================================================

test "whole-range zero-delta whitespace redistribution cannot reuse stale offsets" {
    // Replace `const x=1; ` (11 bytes, spanning real tokens) with
    // `const x=1 ;` — identical real-token tags/lengths/text, zero delta,
    // but the `;` moved by one byte. The gate must reject offset reuse and
    // the safe fallback must produce fresh coordinates.
    const src: [:0]const u8 = "const x=1; const y=2;";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    const next = try Incremental.reparse(gpa, &state, .{
        .start = 0,
        .end = @as(u32, "const x=1; ".len),
        .new_text = "const x=1 ;",
    });
    state.deinit();
    state = next;

    try std.testing.expectEqualStrings("const x=1 ;const y=2;", state.source);
    // Safe fallback: coordinates match a fresh parse of the new source —
    // not the stale pre-edit ones.
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T10 — delete then retype restores the original coordinates.
// =========================================================================

test "delete then retype restores the original coordinates" {
    const src: [:0]const u8 =
        \\const K: i32 = 7;
        \\fn main() -> i32 {
        \\    let v: i32 = K;
        \\    return v;
        \\}
    ;
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const symbols_before = state.module.symbols.items.len;

    // Type `// note` the way a trivia-only session can: the `//` prefix
    // lands as one edit (a lone `/` is a real token), then each content
    // character — every intermediate stays confined to the comment gap.
    const ins_at = at(src, "let v");
    {
        const next = try Incremental.reparse(gpa, &state, .{
            .start = ins_at,
            .end = ins_at,
            .new_text = "//",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }
    const content = " note";
    for (content, 0..) |_, i| {
        const cursor = ins_at + 2 + @as(u32, @intCast(i));
        const next = try Incremental.reparse(gpa, &state, .{
            .start = cursor,
            .end = cursor,
            .new_text = content[i..][0..1],
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }

    // Delete the content one character at a time from the END so every
    // prefix of the comment stays a comment, then remove the `//` whole.
    var remaining: u32 = content.len;
    while (remaining > 0) : (remaining -= 1) {
        const del_at = ins_at + 2 + remaining - 1;
        const next = try Incremental.reparse(gpa, &state, .{
            .start = del_at,
            .end = del_at + 1,
            .new_text = "",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }
    {
        const next = try Incremental.reparse(gpa, &state, .{
            .start = ins_at,
            .end = ins_at + 2,
            .new_text = "",
        });
        state.deinit();
        state = next;
        try expectMatchesFreshParse(&state);
    }

    try std.testing.expectEqualStrings(src, state.source);
    // No tombstones accumulated anywhere along the way.
    try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));
}

// =========================================================================
// T11 — CRLF trivia shifts are byte-exact.
// =========================================================================

test "CRLF trivia shifts are byte-exact" {
    const src: [:0]const u8 = "const a: i32 = 1;\r\nconst b: i32 = 2;\r\nfn f() -> i32 { return a + b; }\r\n";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Insert a CRLF-terminated comment between the decls.
    const ins_at = at(src, "const b");
    var next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "// c\r\n",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try expectMatchesFreshParse(&state);

    // Delete the comment's CONTENT bytes (" c") — still trivia. Deleting
    // the "//" delimiters instead would be semantic: the "c" would lex
    // back as a real identifier token.
    next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at + 2,
        .end = ins_at + 4,
        .new_text = "",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try expectMatchesFreshParse(&state);

    // \r must not be treated as one byte-with-\n: growing a whitespace run
    // that contains \r\n keeps exact positions.
    next = try Incremental.reparse(gpa, &state, .{
        .start = ins_at,
        .end = ins_at,
        .new_text = "\r  ",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T12 — mixed zero/non-zero trivia edits coalesce after 256 hot edits.
// =========================================================================

test "mixed zero/non-zero trivia edits coalesce after 256 hot edits" {
    const src: [:0]const u8 = "// ab\nfn f() -> i32 { return 1; }";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();

    // Alternate a zero-delta comment-text swap (last two chars before the
    // newline) and a one-char comment insert (at the newline). Both must
    // count toward hot_edits_since_full, so the edit after the 256th
    // successful hot edit is a forced full parse.
    var edit_idx: u32 = 0;
    var expected_hot: u16 = 0;
    var forced_fulls: u32 = 0;
    while (edit_idx < 260) : (edit_idx += 1) {
        const nl: u32 = @intCast(std.mem.indexOfScalar(u8, state.source, '\n').?);
        const next = blk: {
            if (edit_idx % 2 == 1) {
                // Non-zero: grow the comment content by one char.
                break :blk try Incremental.reparse(gpa, &state, .{
                    .start = nl,
                    .end = nl,
                    .new_text = "x",
                });
            }
            // Zero-delta: swap the last two comment chars before the \n.
            const a = state.source[nl - 2];
            const b = state.source[nl - 1];
            const swapped = [2]u8{ b, a };
            break :blk try Incremental.reparse(gpa, &state, .{
                .start = nl - 2,
                .end = nl,
                .new_text = &swapped,
            });
        };
        state.deinit();
        state = next;

        if (expected_hot >= Incremental.HOT_EDIT_COALESCE_MAX) {
            // Forced coalescing full parse: not reused, count reset.
            try std.testing.expect(!state.reused);
            try std.testing.expectEqual(@as(u16, 0), state.hot_edits_since_full);
            expected_hot = 0;
            forced_fulls += 1;
        } else {
            try std.testing.expect(state.reused);
            expected_hot += 1;
            try std.testing.expectEqual(expected_hot, state.hot_edits_since_full);
        }
    }
    try std.testing.expect(forced_fulls >= 1);
    // No tombstone churn across the whole session.
    try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));
}

// =========================================================================
// T13 — arena growth is bounded across a long trivia session.
// =========================================================================

test "arena growth is bounded across a long trivia session" {
    // Build a ~24 KB source. Sizing matters: the watermark is
    // max(4 MiB, 8 x source.len), and a fresh full parse of this document
    // must land BELOW it so hot trivia edits accumulate — each one
    // allocates a new source copy + token + node + child-table storage
    // into the arena, crossing the floor after a handful of edits. (A
    // larger source whose parse arena already exceeds the floor would
    // full-parse every edit and exercise nothing.)
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        var line: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(
            &line,
            "fn body_{d:0>3}() -> i32 {{ let local: i32 = {d}; return local; }}\n",
            .{ i, i },
        );
        try big.appendSlice(gpa, s);
    }
    const src = try gpa.dupeZ(u8, big.items);
    defer gpa.free(src);

    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const symbols_before = state.module.symbols.items.len;

    var edits: u32 = 0;
    var forced_fulls: u32 = 0;
    var capacity_before_forced: usize = 0;
    var capacity_after_forced: usize = 0;
    while (edits < 600) : (edits += 1) {
        // Rotate the insert position across lines so every gap gets used.
        // `// x\n` is complete trivia: without the trailing newline the
        // comment would swallow the following declaration.
        const needle = try std.fmt.allocPrint(gpa, "fn body_{d:0>3}", .{edits % 400});
        defer gpa.free(needle);
        const pos = std.mem.indexOf(u8, state.source, needle) orelse return error.NeedleLost;
        // Pre-edit capacity — must be read BEFORE the reparse: a
        // successful hot path moves `state` (its arena transfers to the
        // result), and `arenaBytes` asserts `!moved`.
        const pre_capacity = state.arenaBytes();
        const next = try Incremental.reparse(gpa, &state, .{
            .start = @intCast(pos),
            .end = @intCast(pos),
            .new_text = "// x\n",
        });
        state.deinit();
        state = next;

        if (!state.reused) {
            forced_fulls += 1;
            capacity_before_forced = pre_capacity;
            capacity_after_forced = state.arenaBytes();
        }
        if (edits % 50 == 0) {
            // Symbol count must stay constant across the whole session —
            // trivia edits never churn the symbol table.
            try std.testing.expectEqual(symbols_before, state.module.symbols.items.len);
            try std.testing.expectEqual(@as(usize, 0), countRetired(state.module));
        }
    }

    // Both watermarks must have fired at least once over 600 edits, and a
    // forced full parse must reclaim arena capacity (sawtooth, not ratchet).
    std.debug.print(
        "arena-session: forced_fulls={d} before={d} after={d}\n",
        .{ forced_fulls, capacity_before_forced, capacity_after_forced },
    );
    try std.testing.expect(forced_fulls >= 1);
    try std.testing.expect(capacity_after_forced < capacity_before_forced);
    try expectMatchesFreshParse(&state);
}

// =========================================================================
// T14 — unsupported shift falls back atomically.
// =========================================================================

test "unsupported shift falls back atomically" {
    const src: [:0]const u8 = "const x=1; const y=2;";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const module_before = state.module;
    const version_before = state.module_version;
    const decl_count = state.module.declarations.items.len;

    // Gap-crossing zero-delta redistribution: the gate must reject it and
    // the driver must return a full parse without mutating prev.
    var updated = try Incremental.reparse(gpa, &state, .{
        .start = 0,
        .end = @as(u32, "const x=1; ".len),
        .new_text = "const x=1 ;",
    });
    defer updated.deinit();

    try std.testing.expect(!updated.reused);
    try std.testing.expectEqual(version_before +% 1, updated.module_version);
    try std.testing.expectEqual(@as(u16, 0), updated.hot_edits_since_full);

    // prev was NOT moved and exposes no half-shifted state.
    try std.testing.expect(!state.moved);
    try std.testing.expectEqual(module_before, state.module);
    try std.testing.expectEqualStrings(src, state.module.source);
    try std.testing.expectEqual(decl_count, state.module.declarations.items.len);
    try std.testing.expectEqualStrings("const x=1; const y=2;", state.source);
}

// =========================================================================
// T15 — module_version policy: bump on non-zero delta, preserve on gated
// zero-delta (including a zero-delta edit that still corrects the CST).
// =========================================================================

test "version preserved for gated zero-delta and bumped for non-zero trivia" {
    const src: [:0]const u8 = "/*hh*/ fn f() -> i32 { let v = 1; return v; }";
    var state = try Incremental.parseFull(gpa, src);
    defer state.deinit();
    const v0 = state.module_version;

    // Zero-delta with a trivia-token-count change (one 6-byte comment ->
    // whitespace + 5-byte comment): version preserved, CST corrected.
    var next = try Incremental.reparse(gpa, &state, .{
        .start = 0,
        .end = 6, // "/*hh*/"
        .new_text = " /*q*/",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try std.testing.expectEqual(v0, state.module_version);
    try expectMatchesFreshParse(&state);
    try std.testing.expectEqualStrings(" /*q*/ fn f() -> i32 { let v = 1; return v; }", state.source);

    // Zero-delta, same trivia count, different comment text: the streams
    // are tag/range-identical, so the old CST arrays are reused whole.
    next = try Incremental.reparse(gpa, &state, .{
        .start = 1,
        .end = 6, // "/*q*/"
        .new_text = "/*z*/",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try std.testing.expectEqual(v0, state.module_version);
    try expectMatchesFreshParse(&state);

    // Non-zero: version bumps.
    const fn_at = at(state.source, "fn f()");
    next = try Incremental.reparse(gpa, &state, .{
        .start = fn_at,
        .end = fn_at,
        .new_text = "// h\n",
    });
    state.deinit();
    state = next;
    try std.testing.expect(state.reused);
    try std.testing.expectEqual(v0 +% 1, state.module_version);
    try expectMatchesFreshParse(&state);
}
