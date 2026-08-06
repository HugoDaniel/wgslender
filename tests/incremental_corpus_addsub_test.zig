//! Corpus × mutation-section coverage for `Incremental.reparse`'s
//! add/sub walks.
//!
//! Complements `incremental_corpus_test.zig` (aggregate-sum I-01) and
//! `incremental_mutation_longtail_test.zig` (hand-crafted M1–M8 snippets)
//! by driving each mutation family over every shader in
//! `tests/testdata/compute.toys/` and asserting both a per-name-sum
//! oracle AND a positional per-symbol `use_count` oracle against a
//! fresh `parseFull(new_source)`.
//!
//! Why both oracles: the per-name-sum check catches cross-name drift
//! (a count leaking from `a` to `b`), while the positional per-symbol
//! check catches same-name shadowing drift (a count leaking between
//! two differently-scoped `i` locals). Compute.toys shaders routinely
//! shadow identifiers across scopes, so the per-name sum alone can
//! miss real mode-dispatch corruption.
//!
//! Every driver uses the append-only contract — the in-place compound
//! and decl hot paths (`src/Incremental.zig:842-909, 949-1100,
//! 1140-1310`) may leave dead (`use_count == 0`) symbol-table entries
//! after a sub-walk, which is a feature of the path, not a defect.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;
const Lexer = wgslender.Lexer;

// =========================================================================
// Harness
// =========================================================================

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf[0..bytes.len :0];
}

fn useCountAt(module: *const Ast.Module, idx: usize) u32 {
    if (idx >= module.use_counts.counts.len) return 0;
    return module.use_counts.counts[idx];
}

fn sumUseCountByName(module: *const Ast.Module, name: []const u8) u32 {
    var sum: u32 = 0;
    for (module.symbols.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.original_name, name)) sum += useCountAt(module, i);
    }
    return sum;
}

/// Per-name `use_count` sum equivalence. `got` may carry dead
/// (`use_count == 0`) extras from an in-place hot-path sub-walk; any
/// name with a non-zero count in either module must map to the same
/// live sum.
fn expectUseCountsMatchAppendOnly(
    label: []const u8,
    got: *const Ast.Module,
    oracle: *const Ast.Module,
) !void {
    for (oracle.symbols.items) |o| {
        const g = sumUseCountByName(got, o.original_name);
        const oc = sumUseCountByName(oracle, o.original_name);
        if (g != oc) {
            std.debug.print(
                "{s}: use_count sum mismatch for '{s}': got={d} oracle={d}\n",
                .{ label, o.original_name, g, oc },
            );
            return error.UseCountMismatch;
        }
    }
    for (got.symbols.items, 0..) |g, gi| {
        const oc = sumUseCountByName(oracle, g.original_name);
        const gc = useCountAt(got, gi);
        if (oc == 0 and gc != 0) {
            std.debug.print(
                "{s}: updated-only live symbol '{s}' has non-zero use_count {d}\n",
                .{ label, g.original_name, gc },
            );
            return error.DeadSymbolHasUseCount;
        }
    }
}

/// Per-symbol `use_count` oracle, identity-keyed on the declaration
/// byte offset — strictly stronger than `expectUseCountsMatchAppendOnly`.
///
/// Motivation: compute.toys shaders shadow the same identifier across
/// scopes (multiple `let i`, `let x`, `uv`, …). A mode-dispatch bug
/// that over-increments symbol A's `use_count` and under-decrements
/// symbol B's — where A and B share a name — passes the name-sum
/// oracle because the global sum is preserved. This oracle matches
/// each live symbol by `(original_name, kind, loc)`, which is unique
/// per declaration in a byte-identical source, and asserts
/// `use_count` equality at the matched pair.
///
/// Why `loc` as the disambiguator: every live declaration has a unique
/// byte offset in the new source. Both the incremental path and the
/// oracle's `parseFull` populate `Symbol.loc` from the same byte
/// offset, so matching by `loc` is stable even when the incremental
/// path re-appends a replaced symbol at a different raw index than the
/// oracle's in-source-order layout. A `loc` mismatch is itself a
/// separate bug class (span-shift regressions); the `SymbolNotFound`
/// diagnostic here still surfaces it.
fn expectPerSymbolUseCountsExact(
    gpa: std.mem.Allocator,
    label: []const u8,
    got: *const Ast.Module,
    oracle: *const Ast.Module,
) !void {
    var got_live: std.ArrayListUnmanaged(usize) = .empty;
    defer got_live.deinit(gpa);
    for (got.symbols.items, 0..) |_, i| {
        if (useCountAt(got, i) > 0) try got_live.append(gpa, i);
    }

    var oracle_live: std.ArrayListUnmanaged(usize) = .empty;
    defer oracle_live.deinit(gpa);
    for (oracle.symbols.items, 0..) |_, i| {
        if (useCountAt(oracle, i) > 0) try oracle_live.append(gpa, i);
    }

    if (got_live.items.len != oracle_live.items.len) {
        std.debug.print(
            "{s}: live-symbol count mismatch: got={d} oracle={d}\n",
            .{ label, got_live.items.len, oracle_live.items.len },
        );
        dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
        return error.LiveSymbolCountMismatch;
    }

    // Match each oracle live symbol to exactly one got live symbol by
    // `(name, kind, loc)`. A missing match is a structural defect; a
    // use_count delta at a matched pair is the target failure mode.
    for (oracle_live.items) |oi| {
        const o = oracle.symbols.items[oi];
        var matched: ?usize = null;
        for (got_live.items) |gi| {
            const g = got.symbols.items[gi];
            if (g.kind == o.kind and g.loc == o.loc and std.mem.eql(u8, g.original_name, o.original_name)) {
                matched = gi;
                break;
            }
        }
        const gi = matched orelse {
            std.debug.print(
                "{s}: oracle live symbol ('{s}',{s},loc={d},uc={d}) has no matching live symbol in got\n",
                .{ label, o.original_name, @tagName(o.kind), o.loc, useCountAt(oracle, oi) },
            );
            dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
            return error.LiveSymbolNotFound;
        };
        const g_count = useCountAt(got, gi);
        const o_count = useCountAt(oracle, oi);
        if (g_count != o_count) {
            std.debug.print(
                "{s}: use_count mismatch for ('{s}',{s},loc={d}): got={d} oracle={d}\n",
                .{ label, o.original_name, @tagName(o.kind), o.loc, g_count, o_count },
            );
            dumpLiveSideBySide(label, got, got_live.items, oracle, oracle_live.items);
            return error.PerSymbolUseCountMismatch;
        }
    }
}

fn dumpLiveSideBySide(
    label: []const u8,
    got: *const Ast.Module,
    got_live: []const usize,
    oracle: *const Ast.Module,
    oracle_live: []const usize,
) void {
    std.debug.print("{s}: live symbol table (got | oracle):\n", .{label});
    const n = @max(got_live.len, oracle_live.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i < got_live.len) {
            const g = got.symbols.items[got_live[i]];
            std.debug.print(
                "  got[{d:>3}] raw={d:>3} name={s:<24} kind={s:<10} loc={d:>4} uc={d}",
                .{ i, got_live[i], g.original_name, @tagName(g.kind), g.loc, useCountAt(got, got_live[i]) },
            );
        } else {
            std.debug.print("  got[{d:>3}] --", .{i});
        }
        if (i < oracle_live.len) {
            const o = oracle.symbols.items[oracle_live[i]];
            std.debug.print(
                "  |  oracle[{d:>3}] raw={d:>3} name={s:<24} kind={s:<10} loc={d:>4} uc={d}\n",
                .{ i, oracle_live[i], o.original_name, @tagName(o.kind), o.loc, useCountAt(oracle, oracle_live[i]) },
            );
        } else {
            std.debug.print("  |  oracle[{d:>3}] --\n", .{i});
        }
    }
}

/// Length-preserving leading-digit swap. Used by integer-literal edits
/// to keep subsequent byte offsets stable across the splice.
fn flipDigit(byte: u8) []const u8 {
    return switch (byte) {
        '0', '1', '2', '3', '4' => "9",
        else => "0",
    };
}

fn applyEdit(
    gpa: std.mem.Allocator,
    src: []const u8,
    edit: Incremental.Edit,
) ![]u8 {
    const new_len = src.len - (edit.end - edit.start) + edit.new_text.len;
    const out = try gpa.alloc(u8, new_len);
    @memcpy(out[0..edit.start], src[0..edit.start]);
    @memcpy(out[edit.start..][0..edit.new_text.len], edit.new_text);
    @memcpy(
        out[edit.start + edit.new_text.len ..],
        src[edit.end..],
    );
    return out;
}

/// One edit applied to `base`, oracle-checked against a fresh parse of
/// the spliced source. Source splice equality, declaration count
/// equality, and per-name `use_count` sum equality are all enforced.
fn runCorpusEdit(
    gpa: std.mem.Allocator,
    label: []const u8,
    base: *Incremental.ReparseResult,
    edit: Incremental.Edit,
) !void {
    const expected_new = try applyEdit(gpa, base.source, edit);
    defer gpa.free(expected_new);

    var updated = try Incremental.reparse(gpa, base, edit);
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected_new, updated.source);

    var oracle = try Incremental.parseFull(gpa, updated.source);
    defer oracle.deinit();

    if (oracle.module.declarations.items.len != updated.module.declarations.items.len) {
        std.debug.print(
            "{s}: decl count mismatch: got={d} oracle={d}\n",
            .{ label, updated.module.declarations.items.len, oracle.module.declarations.items.len },
        );
        return error.DeclCountMismatch;
    }

    try expectUseCountsMatchAppendOnly(label, updated.module, oracle.module);
    try expectPerSymbolUseCountsExact(gpa, label, updated.module, oracle.module);
}

/// Walk the compute.toys directory once, invoking `visit(entry_name,
/// source_z)` for every `.wgsl` file. Returns the number of shaders
/// visited. Absent directory is a graceful skip, matching the existing
/// corpus-test convention (`incremental_corpus_test.zig:54-60`).
fn walkCorpus(
    gpa: std.mem.Allocator,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime visit: fn (ctx: *Ctx, name: []const u8, source_z: [:0]const u8) anyerror!void,
) !usize {
    const io = std.Options.debug_io;
    const dir_path = "tests/testdata/compute.toys";

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("skip: compute.toys directory missing\n", .{});
            return 0;
        }
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            continue;
        };
        const src_z = try makeSentinel(alloc, bytes);

        try visit(ctx, entry.basename, src_z);
        n += 1;
    }
    return n;
}

// =========================================================================
// Token utilities — find anchors across a shader without duplicating
// the lexer in every driver.
// =========================================================================

const TokenCursor = struct {
    tags: []const Lexer.Tag,
    starts: []const u32,
    ends: []const u32,

    fn init(toks: *const std.MultiArrayList(Lexer.Token)) TokenCursor {
        return .{
            .tags = toks.items(.tag),
            .starts = toks.items(.start),
            .ends = toks.items(.end),
        };
    }

    /// Return the index of the first non-trivia token at or after `i`.
    fn skipTrivia(self: TokenCursor, i: usize) usize {
        var j = i;
        while (j < self.tags.len and self.tags[j].isTrivia()) j += 1;
        return j;
    }
};

/// Index of the first integer literal that appears inside a function
/// body (i.e., after the first `keyword_fn` + balanced-paren
/// signature + the opening `l_brace`). Returns `null` if no such
/// literal exists.
fn firstBodyIntLiteral(cur: TokenCursor) ?usize {
    var i: usize = 0;
    // Seek `keyword_fn`.
    while (i < cur.tags.len and cur.tags[i] != .keyword_fn) : (i += 1) {}
    if (i == cur.tags.len) return null;
    // Walk until we enter a function body. The body opens at the first
    // `l_brace` whose paren depth is zero.
    var paren_depth: i32 = 0;
    var in_body = false;
    while (i < cur.tags.len) : (i += 1) {
        const t = cur.tags[i];
        switch (t) {
            .l_paren => paren_depth += 1,
            .r_paren => paren_depth -= 1,
            .l_brace => {
                if (paren_depth == 0) {
                    in_body = true;
                    i += 1;
                    break;
                }
            },
            else => {},
        }
    }
    if (!in_body) return null;

    // Scan body tokens for an int_literal.
    while (i < cur.tags.len) : (i += 1) {
        if (cur.tags[i] == .int_literal) return i;
    }
    return null;
}

/// Index of the first integer literal inside an attribute's argument
/// list: `@ident( … int_literal … )`. Returns `null` if no such
/// literal exists in the shader.
fn firstAttributeIntLiteral(cur: TokenCursor) ?usize {
    var i: usize = 0;
    while (i < cur.tags.len) : (i += 1) {
        if (cur.tags[i] != .at) continue;
        // Pattern: @ (ident) (l_paren) … int_literal … r_paren
        const after_at = cur.skipTrivia(i + 1);
        if (after_at >= cur.tags.len or cur.tags[after_at] != .ident) continue;
        const after_name = cur.skipTrivia(after_at + 1);
        if (after_name >= cur.tags.len or cur.tags[after_name] != .l_paren) continue;

        var j = after_name + 1;
        var depth: i32 = 1;
        while (j < cur.tags.len and depth > 0) : (j += 1) {
            switch (cur.tags[j]) {
                .l_paren => depth += 1,
                .r_paren => depth -= 1,
                .int_literal => if (depth > 0) return j,
                else => {},
            }
        }
    }
    return null;
}

/// Find the first `return EXPR ;` inside a function body and return
/// `[expr_start, expr_end)` byte offsets. Skips bare `return;`.
fn firstReturnExprRange(cur: TokenCursor) ?struct { start: u32, end: u32 } {
    var i: usize = 0;
    while (i < cur.tags.len) : (i += 1) {
        if (cur.tags[i] != .keyword_return) continue;
        const after = cur.skipTrivia(i + 1);
        if (after >= cur.tags.len or cur.tags[after] == .semicolon) continue;

        // Walk forward until semicolon at depth 0. Depth tracks paren &
        // bracket nesting; a `{` terminates the scan because a return
        // can't span a block boundary.
        var j = after;
        var depth: i32 = 0;
        const expr_first = j;
        while (j < cur.tags.len) : (j += 1) {
            const t = cur.tags[j];
            switch (t) {
                .l_paren, .l_bracket => depth += 1,
                .r_paren, .r_bracket => depth -= 1,
                .semicolon => if (depth == 0) {
                    // Walk back over trailing trivia.
                    var end_tok = j;
                    while (end_tok > expr_first and cur.tags[end_tok - 1].isTrivia()) {
                        end_tok -= 1;
                    }
                    return .{
                        .start = cur.starts[expr_first],
                        .end = cur.ends[end_tok - 1],
                    };
                },
                .l_brace, .r_brace => return null,
                else => {},
            }
        }
        return null;
    }
    return null;
}

/// Find the first `for (` loop's condition `<` operator, returning its
/// `[start, end)` byte range. Used by C-M6 to flip `<` → `<=`.
fn firstForLoopLessThanRange(cur: TokenCursor) ?struct { start: u32, end: u32 } {
    var i: usize = 0;
    while (i < cur.tags.len) : (i += 1) {
        if (cur.tags[i] != .keyword_for) continue;
        const lp = cur.skipTrivia(i + 1);
        if (lp >= cur.tags.len or cur.tags[lp] != .l_paren) continue;

        // First `;` terminates init; the next section is the condition.
        var j = lp + 1;
        var depth: i32 = 1;
        while (j < cur.tags.len and depth > 0) : (j += 1) {
            switch (cur.tags[j]) {
                .l_paren => depth += 1,
                .r_paren => depth -= 1,
                .semicolon => if (depth == 1) {
                    j += 1;
                    break;
                },
                else => {},
            }
        } else return null;

        // In the condition section, the first `lt` at depth 1 is our
        // target. Depth can grow with nested calls; stop at the next
        // top-level `;` which closes the condition.
        var k = j;
        var d: i32 = 1;
        while (k < cur.tags.len) : (k += 1) {
            switch (cur.tags[k]) {
                .l_paren => d += 1,
                .r_paren => d -= 1,
                .semicolon => if (d == 1) return null,
                .lt => if (d == 1) return .{ .start = cur.starts[k], .end = cur.ends[k] },
                else => {},
            }
        }
        return null;
    }
    return null;
}

/// Find the first `if (cond)` condition range — the byte slice
/// strictly between `if (` and the matching `)`.
fn firstIfConditionRange(cur: TokenCursor) ?struct { start: u32, end: u32 } {
    var i: usize = 0;
    while (i < cur.tags.len) : (i += 1) {
        if (cur.tags[i] != .keyword_if) continue;
        const lp = cur.skipTrivia(i + 1);
        if (lp >= cur.tags.len or cur.tags[lp] != .l_paren) continue;

        var j = lp + 1;
        var depth: i32 = 1;
        const cond_start_tok = j;
        while (j < cur.tags.len and depth > 0) : (j += 1) {
            switch (cur.tags[j]) {
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        // Walk back over trailing trivia inside parens.
                        var end_tok = j;
                        while (end_tok > cond_start_tok and cur.tags[end_tok - 1].isTrivia()) {
                            end_tok -= 1;
                        }
                        if (end_tok == cond_start_tok) return null;
                        return .{
                            .start = cur.starts[cond_start_tok],
                            .end = cur.ends[end_tok - 1],
                        };
                    }
                },
                else => {},
            }
        }
        return null;
    }
    return null;
}

// =========================================================================
// C-M1 — attribute-argument literal flip on every shader.
//
// Attribute args don't contribute to `use_count` (see the M1 block of
// `incremental_mutation_longtail_test.zig`), so any per-symbol drift is
// a bug. Length-preserving digit swap keeps token positions stable.
// =========================================================================

test "C-M1: attribute literal flip on compute.toys preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const idx = firstAttributeIntLiteral(cur) orelse {
                self.n_skip += 1;
                return;
            };
            const lit_start = cur.starts[idx];
            const lit_end = cur.ends[idx];
            if (lit_end - lit_start < 1) return;

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M1 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = lit_start,
                .end = lit_start + 1,
                .new_text = flipDigit(src_z[lit_start]),
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M1 attribute literal flip: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    // At least one compute.toys shader carries an attribute integer.
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M2 — integer literal inside a function body.
//
// Exercises the `literal_expr` anchor on the hot path. `F-CORPUS`
// already covers the error-list oracle; here we specifically assert
// per-symbol use_count equivalence, which F-CORPUS does not.
// =========================================================================

test "C-M2: body literal flip on compute.toys preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const idx = firstBodyIntLiteral(cur) orelse {
                self.n_skip += 1;
                return;
            };
            const lit_start = cur.starts[idx];
            const lit_end = cur.ends[idx];
            if (lit_end - lit_start < 1) return;

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M2 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = lit_start,
                .end = lit_start + 1,
                .new_text = flipDigit(src_z[lit_start]),
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M2 body literal flip: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M3 — parenthesize the first `return EXPR;` in each shader.
//
// The sub-walk decrements `use_count` for every ident in EXPR; the
// add-walk reincrements them at identical counts. Per-name sums must
// be unchanged versus the oracle. This is the sharpest single-edit
// add/sub test: any mismatch between the sub and add passes shows up.
// =========================================================================

test "C-M3: parenthesize return expression preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const range = firstReturnExprRange(cur) orelse {
                self.n_skip += 1;
                return;
            };

            const expr_text = src_z[range.start..range.end];
            const wrapped = try std.fmt.allocPrint(self.gpa, "({s})", .{expr_text});
            defer self.gpa.free(wrapped);

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M3 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = range.start,
                .end = range.end,
                .new_text = wrapped,
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M3 parenthesize return: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M4 — inverse of C-M3: un-parenthesize a pre-parenthesized return.
//
// Base here is the edited result of C-M3 (text spliced manually). The
// edit peels the outer parens, driving a sub-walk on `(EXPR)` and an
// add-walk on `EXPR`. Catches an asymmetric sub-walk that the C-M3
// direction alone might not trip.
// =========================================================================

test "C-M4: inverse of return-parenthesize preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const range = firstReturnExprRange(cur) orelse {
                self.n_skip += 1;
                return;
            };

            const expr_text = src_z[range.start..range.end];
            const wrapped = try std.fmt.allocPrint(self.gpa, "({s})", .{expr_text});
            defer self.gpa.free(wrapped);

            // Synthesize the parenthesized source as our "base" in a single
            // sentinel-terminated allocation (no intermediate copies).
            const paren_len = src_z.len - (range.end - range.start) + wrapped.len;
            const paren_src_z = try self.gpa.allocSentinel(u8, paren_len, 0);
            defer self.gpa.free(paren_src_z);
            @memcpy(paren_src_z[0..range.start], src_z[0..range.start]);
            @memcpy(paren_src_z[range.start..][0..wrapped.len], wrapped);
            @memcpy(paren_src_z[range.start + wrapped.len ..], src_z[range.end..]);

            var base = try Incremental.parseFull(self.gpa, paren_src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M4 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = range.start,
                .end = range.start + @as(u32, @intCast(wrapped.len)),
                .new_text = expr_text,
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M4 un-parenthesize return: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M5 — round-trip: parenthesize then un-parenthesize. Final source
// must be byte-identical to the original; per-name use_count sums
// must match the original's — not just a fresh-parse oracle.
// =========================================================================

test "C-M5: return-expr parenthesize/un-parenthesize round-trip" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const range = firstReturnExprRange(cur) orelse {
                self.n_skip += 1;
                return;
            };

            const expr_text = src_z[range.start..range.end];
            const wrapped = try std.fmt.allocPrint(self.gpa, "({s})", .{expr_text});
            defer self.gpa.free(wrapped);

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            var fwd = try Incremental.reparse(self.gpa, &base, .{
                .start = range.start,
                .end = range.end,
                .new_text = wrapped,
            });
            defer fwd.deinit();

            var back = try Incremental.reparse(self.gpa, &fwd, .{
                .start = range.start,
                .end = range.start + @as(u32, @intCast(wrapped.len)),
                .new_text = expr_text,
            });
            defer back.deinit();

            try std.testing.expectEqualStrings(src_z, back.source);

            const label = try std.fmt.allocPrint(self.gpa, "C-M5 {s}", .{name});
            defer self.gpa.free(label);
            try expectUseCountsMatchAppendOnly(label, back.module, base.module);
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M5 return-parenthesize round-trip: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M6 — for-loop condition comparator flip: `<` → `<=`.
//
// A length-changing edit (1 byte → 2 bytes) inside a `for_stmt`
// condition slot. Exercises the span-shift pass with `delta = 1` and
// re-resolution of the loop variable (`i`) and its right-hand side on
// both walks.
// =========================================================================

test "C-M6: for-loop '<' → '<=' preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const range = firstForLoopLessThanRange(cur) orelse {
                self.n_skip += 1;
                return;
            };

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M6 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = range.start,
                .end = range.end,
                .new_text = "<=",
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M6 for-loop comparator: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    // Four of the seven compute.toys shaders carry `for (…; i < …; …)`.
    try std.testing.expect(v.n_hits >= 3);
}

// =========================================================================
// C-M7 — parenthesize the first `if (cond)` condition.
//
// Drives the `if_stmt` condition anchor. Like C-M3 but targets a
// statement-level anchor that the lowering pass treats differently:
// `if` conditions are visited before body scopes open, so an
// asymmetric add/sub in the wrong scope surfaces here.
// =========================================================================

test "C-M7: parenthesize if-condition preserves per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const range = firstIfConditionRange(cur) orelse {
                self.n_skip += 1;
                return;
            };

            const cond_text = src_z[range.start..range.end];
            const wrapped = try std.fmt.allocPrint(self.gpa, "({s})", .{cond_text});
            defer self.gpa.free(wrapped);

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M7 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = range.start,
                .end = range.end,
                .new_text = wrapped,
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M7 parenthesize if-cond: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M8 — append a probe `let probe_99 = 0;` inside the last function
// body (before its closing `}`). Pure add-path; no sub. Every existing
// per-name use_count sum must be unchanged; the oracle gains exactly
// one new symbol (`probe_99`) with `use_count == 0`.
// =========================================================================

test "C-M8: body-probe append preserves existing per-symbol use_count" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            const close_off_o = std.mem.lastIndexOfScalar(u8, src_z, '}');
            if (close_off_o == null) {
                self.n_skip += 1;
                return;
            }
            const close_off: u32 = @intCast(close_off_o.?);

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            const label = try std.fmt.allocPrint(self.gpa, "C-M8 {s}", .{name});
            defer self.gpa.free(label);
            try runCorpusEdit(self.gpa, label, &base, .{
                .start = close_off,
                .end = close_off,
                .new_text = " let probe_99 = 0;",
            });
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M8 body-probe append: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}

// =========================================================================
// C-M9 — compose two non-overlapping edits: an attribute literal flip
// (C-M1-style) followed by a body literal flip (C-M2-style). The two
// anchors live in different parts of the CST; composition across a
// parseFull + hot-path boundary must agree with a single parseFull of
// the twice-edited source.
// =========================================================================

test "C-M9: composed attribute + body literal edits agree with oracle" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const Visitor = struct {
        gpa: std.mem.Allocator,
        n_hits: usize = 0,
        n_skip: usize = 0,

        fn visit(self: *@This(), name: []const u8, src_z: [:0]const u8) anyerror!void {
            var toks = try Lexer.tokenizeAll(self.gpa, src_z);
            defer toks.deinit(self.gpa);
            const cur = TokenCursor.init(&toks);

            const attr_idx = firstAttributeIntLiteral(cur) orelse {
                self.n_skip += 1;
                return;
            };
            const body_idx = firstBodyIntLiteral(cur) orelse {
                self.n_skip += 1;
                return;
            };

            const attr_start = cur.starts[attr_idx];
            const body_start = cur.starts[body_idx];

            // Guard: we need the attribute edit strictly before the body
            // edit so the body offset remains valid after the first
            // (length-preserving) splice.
            if (attr_start >= body_start) {
                self.n_skip += 1;
                return;
            }

            var base = try Incremental.parseFull(self.gpa, src_z);
            defer base.deinit();

            var after_attr = try Incremental.reparse(self.gpa, &base, .{
                .start = attr_start,
                .end = attr_start + 1,
                .new_text = flipDigit(src_z[attr_start]),
            });
            defer after_attr.deinit();

            var after_body = try Incremental.reparse(self.gpa, &after_attr, .{
                .start = body_start,
                .end = body_start + 1,
                .new_text = flipDigit(src_z[body_start]),
            });
            defer after_body.deinit();

            var oracle = try Incremental.parseFull(self.gpa, after_body.source);
            defer oracle.deinit();

            try std.testing.expectEqual(
                oracle.module.declarations.items.len,
                after_body.module.declarations.items.len,
            );

            const label = try std.fmt.allocPrint(self.gpa, "C-M9 {s}", .{name});
            defer self.gpa.free(label);
            try expectUseCountsMatchAppendOnly(label, after_body.module, oracle.module);
            self.n_hits += 1;
        }
    };

    var v: Visitor = .{ .gpa = gpa };
    const n = try walkCorpus(gpa, Visitor, &v, Visitor.visit);

    std.debug.print(
        "C-M9 composed attr+body edits: {d} shaders ({d} hit, {d} skip)\n",
        .{ n, v.n_hits, v.n_skip },
    );
    try std.testing.expect(v.n_hits > 0);
}
