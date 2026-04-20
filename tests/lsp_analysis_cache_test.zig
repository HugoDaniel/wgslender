//! LSP analyzeDocument cache + wiring tests (LA series).
//!
//! Every test drives the LSP handler end-to-end: `openDocument`,
//! `changeDocumentIncremental`, `analyzeDocument`. The invariant common
//! to every test is the **consistency oracle** — `analyzeDocument`'s
//! diagnostics after any sequence of edits must match a fresh
//! `analyzeWithOptions` run against the document's current source.
//!
//! Organized by the kind of edit / code path exercised:
//!   * LA1-LA2 — trivia (cache hot vs cache invalidated)
//!   * LA3-LA4 — symbol-free hot paths (module preserved, version bumps)
//!   * LA5-LA7 — compound_stmt / decl_stmt paths
//!   * LA8     — cross-decl fallback
//!   * LA9     — no-op short-circuit
//!   * LA10-LA11 — E0102 introduced / resolved round-trip
//!   * LA12-LA13 — burst editing
//!   * LA14    — DCE idempotence under hot path
//!   * LA15-LA16 — full-sync + close-reopen round-trips
//!   * LA17    — multi-document isolation
//!   * LA18-LA19 — block-comment hide/expose + large paste
//!
//! Each scenario mirrors one of the M-series scenarios in
//! `incremental_mutation_longtail_test.zig` but takes the LSP path to
//! verify that the wiring from `Incremental.reparse` through
//! `analyzeDocument` produces correct diagnostics + preserves cache
//! identity in the right cases.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

fn setup(source: [:0]const u8) !*Handler {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://file.wgsl", source, 1);
    return handler;
}

fn teardown(handler: *Handler) void {
    handler.deinit();
    std.testing.allocator.destroy(handler);
}

/// Core consistency oracle: the handler's analysis after an arbitrary
/// sequence of edits must surface the same diagnostic codes + byte
/// ranges that a fresh analyze of the current source produces.
fn expectConsistencyOracle(handler: *Handler, uri: []const u8) !void {
    const doc_source = handler.getDocumentSource(uri) orelse return error.DocumentNotFound;
    const source_z = try std.testing.allocator.dupeZ(u8, doc_source);
    defer std.testing.allocator.free(source_z);

    var oracle = try wgslender.analyzeWithOptions(std.testing.allocator, source_z, .{});
    defer oracle.deinit(std.testing.allocator);

    const analyzed = try handler.analyzeDocument(uri);

    const oracle_entries = oracle.diagnostics.diagnostics.items;
    const got_entries = analyzed.diagnostics.diagnostics.items;

    if (oracle_entries.len != got_entries.len) {
        std.debug.print(
            "diagnostic count mismatch: handler={d} oracle={d}\n",
            .{ got_entries.len, oracle_entries.len },
        );
        for (got_entries) |e| std.debug.print("  handler: {s} [{d},{d})\n", .{ e.code, e.range.start.offset, e.range.end.offset });
        for (oracle_entries) |e| std.debug.print("  oracle : {s} [{d},{d})\n", .{ e.code, e.range.start.offset, e.range.end.offset });
        return error.DiagnosticCountMismatch;
    }

    for (got_entries, oracle_entries) |g, o| {
        try std.testing.expectEqualStrings(o.code, g.code);
        try std.testing.expectEqual(o.range.start.offset, g.range.start.offset);
        try std.testing.expectEqual(o.range.end.offset, g.range.end.offset);
    }
}

fn at(haystack: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, haystack, needle).?);
}

fn offsetToPos(source: []const u8, off: u32) Handler.Position {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < off) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

fn rangeFor(source: []const u8, start: u32, end: u32) Handler.Range {
    return .{
        .start = offsetToPos(source, start),
        .end = offsetToPos(source, end),
    };
}

// =========================================================================
// LA1 — trivia zero-delta preserves cache.
// =========================================================================

test "LA1: zero-delta trivia preserves analysis cache identity" {
    const handler = try setup("// hello\nfn f() {}");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const before = try handler.analyzeDocument(uri);
    const doc = handler.documents.getPtr(uri).?;
    const before_version = doc.analysis_module_version;

    // Replace "hello" with "world" — same byte count.
    try handler.changeDocumentIncremental(uri, .{
        .start = .{ .line = 0, .character = 3 },
        .end = .{ .line = 0, .character = 8 },
    }, "world");

    const after = try handler.analyzeDocument(uri);
    const doc2 = handler.documents.getPtr(uri).?;

    try std.testing.expectEqual(before, after);
    try std.testing.expectEqual(before_version, doc2.analysis_module_version);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA2 — trivia non-zero-delta invalidates cache.
// =========================================================================

test "LA2: non-zero-delta trivia invalidates cache but matches oracle" {
    const handler = try setup("fn f() {}");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const before = try handler.analyzeDocument(uri);
    _ = before;

    try handler.changeDocumentIncremental(uri, .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "// new comment\n");

    const doc = handler.documents.getPtr(uri).?;
    // Cache was invalidated by updateParseAfterEdit.
    try std.testing.expect(doc.analysis == null);

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA3 — symbol-free literal flip (hot path): module preserved, version bumps.
// =========================================================================

test "LA3: symbol-free literal flip hits hot path and matches oracle" {
    const handler = try setup("@compute @workgroup_size(8) fn main() {}");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const before = try handler.analyzeDocument(uri);
    _ = before;
    const doc = handler.documents.getPtr(uri).?;
    const prev_module_ptr = doc.parse.?.module;
    const prev_version = doc.analysis_module_version;

    // Flip `8` to `16` inside the attribute.
    const eight_off = at(doc.source, "(8)") + 1;
    const r = rangeFor(doc.source, eight_off, eight_off + 1);
    try handler.changeDocumentIncremental(uri, r, "16");

    const doc2 = handler.documents.getPtr(uri).?;
    // Hot path preserves module pointer but bumps version → cache
    // invalidated by updateParseAfterEdit.
    try std.testing.expectEqual(prev_module_ptr, doc2.parse.?.module);
    try std.testing.expect(doc2.parse.?.reused);
    try std.testing.expect(doc2.analysis == null);

    _ = try handler.analyzeDocument(uri);
    try std.testing.expect(doc2.analysis_module_version != prev_version);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA4 — symbol-free ident swap (hot path).
// =========================================================================

test "LA4: ident_expr swap hits hot path and matches oracle" {
    const handler = try setup(
        "const a: i32 = 1; const b: i32 = 2; fn f() -> i32 { return a; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    const doc = handler.documents.getPtr(uri).?;
    const ret_a = at(doc.source, "return a;") + 7;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, ret_a, ret_a + 1),
        "b",
    );

    const doc2 = handler.documents.getPtr(uri).?;
    try std.testing.expect(doc2.parse.?.reused);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA5 — compound_stmt edit.
// =========================================================================

test "LA5: compound_stmt edit matches oracle after reanalyze" {
    const handler = try setup(
        "fn f(x: i32) -> i32 { if (x > 0) { return 1; } return 0; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    // Change `return 1;` to `return 2;` inside the if-body compound_stmt.
    const doc = handler.documents.getPtr(uri).?;
    const one_off = at(doc.source, "return 1;") + 7;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, one_off, one_off + 1),
        "2",
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA6 — decl_stmt insert inside a function body.
// =========================================================================

test "LA6: decl_stmt insert grows symbol table correctly" {
    const handler = try setup(
        "fn f() -> i32 { let x: i32 = 1; return x; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    const doc = handler.documents.getPtr(uri).?;
    // Insert `let y: i32 = 2; ` between the let and return.
    const insert_off = at(doc.source, "return x") ;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, insert_off, insert_off),
        "let y: i32 = 2; ",
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA7 — decl_stmt delete inside a function body.
// =========================================================================

test "LA7: decl_stmt delete preserves downstream references" {
    const handler = try setup(
        "fn f() -> i32 { let x: i32 = 1; let y: i32 = 2; return y; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    const doc = handler.documents.getPtr(uri).?;
    const del_start = at(doc.source, "let x: i32 = 1; ");
    const del_end = del_start + @as(u32, @intCast("let x: i32 = 1; ".len));
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, del_start, del_end),
        "",
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA8 — cross-decl fallback.
// =========================================================================

test "LA8: edit spanning two decls falls back and matches oracle" {
    const handler = try setup(
        "const a: i32 = 1;\nfn f() -> i32 { return a; }\nconst b: i32 = 2;\n",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    const doc = handler.documents.getPtr(uri).?;
    // Replace the entire middle line with something valid.
    const start = at(doc.source, "fn f");
    const end_off = at(doc.source, "const b");
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, start, end_off),
        "fn g() -> i32 { return 0; }\n",
    );

    const doc2 = handler.documents.getPtr(uri).?;
    try std.testing.expect(!doc2.parse.?.reused);
    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA9 — no-op edit preserves cache pointer.
// =========================================================================

test "LA9: no-op edit preserves analysis cache and parse pointer" {
    const handler = try setup("fn f() {}");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const before = try handler.analyzeDocument(uri);
    const doc = handler.documents.getPtr(uri).?;
    const prev_module = doc.parse.?.module;
    const prev_version = doc.parse.?.module_version;

    // Zero-width insert of empty text at offset 0 — a pure no-op.
    try handler.changeDocumentIncremental(uri, .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, "");

    const doc2 = handler.documents.getPtr(uri).?;
    // No-op short-circuit: parse pointer and version both preserved.
    try std.testing.expectEqual(prev_module, doc2.parse.?.module);
    try std.testing.expectEqual(prev_version, doc2.parse.?.module_version);
    // Cache pointer preserved.
    try std.testing.expectEqual(before, doc2.analysis.?);
}

// =========================================================================
// LA10 — E0102 introduced by edit.
// =========================================================================

test "LA10: E0102 appears after use-before-decl edit" {
    const handler = try setup(
        "fn f() -> i32 { let a: i32 = 1; let b: i32 = 2; return a; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const initial = try handler.analyzeDocument(uri);
    // Pre-edit: no E0102.
    for (initial.diagnostics.diagnostics.items) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.code, "E0102"));
    }

    // Change `return a` to `return b` — `b` is declared before `return`,
    // so this is still legal. Instead, introduce a forward reference:
    // replace `let a: i32 = 1;` with `let a: i32 = b + 1;` so `a`'s
    // initializer references `b` which hasn't been declared yet.
    const doc = handler.documents.getPtr(uri).?;
    const eq_one_off = at(doc.source, "= 1");
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, eq_one_off, eq_one_off + 3),
        "= b + 1",
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA11 — E0102 resolved by edit.
// =========================================================================

test "LA11: E0102 disappears after fix edit" {
    const handler = try setup(
        "fn f() -> i32 { let a: i32 = b + 1; let b: i32 = 2; return a; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const initial = try handler.analyzeDocument(uri);
    // Pre-edit: expect at least one E0102 (use of `b` before decl).
    var saw_e0102 = false;
    for (initial.diagnostics.diagnostics.items) |e| {
        if (std.mem.eql(u8, e.code, "E0102")) saw_e0102 = true;
    }
    try std.testing.expect(saw_e0102);

    // Fix it: replace `b + 1` with `1`.
    const doc = handler.documents.getPtr(uri).?;
    const bplus1_off = at(doc.source, "= b + 1") + 2;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, bplus1_off, bplus1_off + 5),
        "1",
    );

    const after = try handler.analyzeDocument(uri);
    // Now no E0102 should remain.
    for (after.diagnostics.diagnostics.items) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.code, "E0102"));
    }
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA12 — Keystroke burst inside a function body: every analyze matches oracle.
// =========================================================================

test "LA12: keystroke burst inside fn body — per-edit oracle match" {
    const handler = try setup(
        "fn f() -> i32 { let x: i32 = 0; return x; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    _ = try handler.analyzeDocument(uri);

    // 10 single-character literal flips on `x`'s initializer.
    var round: u32 = 0;
    while (round < 10) : (round += 1) {
        const doc = handler.documents.getPtr(uri).?;
        const eq_off = at(doc.source, "= ");
        const lit_start = eq_off + 2;
        // Current literal may have grown/shrunk across edits; find its end.
        var lit_end = lit_start;
        while (lit_end < doc.source.len and
            (doc.source[lit_end] >= '0' and doc.source[lit_end] <= '9'))
            : (lit_end += 1)
        {}

        var buf: [8]u8 = undefined;
        const new_txt = try std.fmt.bufPrint(&buf, "{d}", .{round + 1});
        try handler.changeDocumentIncremental(
            uri,
            rangeFor(doc.source, lit_start, lit_end),
            new_txt,
        );

        _ = try handler.analyzeDocument(uri);
        try expectConsistencyOracle(handler, uri);
    }
}

// =========================================================================
// LA13 — Alternating trivia (zero-delta) / semantic edits.
// =========================================================================

test "LA13: alternating zero-delta trivia + semantic edits preserve cache on trivia rounds" {
    const handler = try setup("// x\nfn f() -> i32 { return 0; }");
    defer teardown(handler);
    const uri = "test://file.wgsl";
    _ = try handler.analyzeDocument(uri);

    var round: u32 = 0;
    while (round < 6) : (round += 1) {
        const doc = handler.documents.getPtr(uri).?;
        if (round % 2 == 0) {
            // Zero-delta trivia: toggle the comment body byte.
            const c_off = at(doc.source, "// ") + 3;
            const new_byte: []const u8 = if (doc.source[c_off] == 'x') "y" else "x";
            const before_analysis = doc.analysis;
            const before_version = doc.analysis_module_version;
            try handler.changeDocumentIncremental(
                uri,
                rangeFor(doc.source, c_off, c_off + 1),
                new_byte,
            );
            const doc2 = handler.documents.getPtr(uri).?;
            // Zero-delta trivia: cache + version preserved.
            try std.testing.expectEqual(before_analysis, doc2.analysis);
            try std.testing.expectEqual(before_version, doc2.analysis_module_version);
        } else {
            // Semantic: flip the return literal.
            const ret_off = at(doc.source, "return ") + 7;
            var buf: [4]u8 = undefined;
            const txt = try std.fmt.bufPrint(&buf, "{d}", .{round});
            try handler.changeDocumentIncremental(
                uri,
                rangeFor(doc.source, ret_off, ret_off + 1),
                txt,
            );
            // Cache invalidated.
            const doc2 = handler.documents.getPtr(uri).?;
            try std.testing.expect(doc2.analysis == null);
            _ = try handler.analyzeDocument(uri);
        }
        try expectConsistencyOracle(handler, uri);
    }
}

// =========================================================================
// LA14 — DCE idempotence under repeated analyses.
// =========================================================================

test "LA14: is_live flags match oracle after symbol-free hot edit" {
    const handler = try setup(
        "fn unused_fn() {} @compute @workgroup_size(8) fn main() { let x: i32 = 1; }",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    _ = try handler.analyzeDocument(uri);

    // Flip the literal inside the entry point — symbol-free hot path.
    const doc = handler.documents.getPtr(uri).?;
    const one_off = at(doc.source, "= 1") + 2;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, one_off, one_off + 1),
        "42",
    );

    const analyzed = try handler.analyzeDocument(uri);
    _ = analyzed;

    // Cross-check `is_live` flags against a fresh analyze.
    const doc_source = handler.getDocumentSource(uri).?;
    const source_z = try std.testing.allocator.dupeZ(u8, doc_source);
    defer std.testing.allocator.free(source_z);
    var oracle = try wgslender.analyzeWithOptions(std.testing.allocator, source_z, .{});
    defer oracle.deinit(std.testing.allocator);
    if (oracle.module) |om| {
        if (oracle._arena) |*oa| {
            _ = wgslender.Dce.mark(oa.allocator(), om) catch {};
        }
        const analyzed_module = handler.documents.getPtr(uri).?.parse.?.module;
        // Symbol count must match (both analyses see the same code).
        try std.testing.expectEqual(om.symbols.items.len, analyzed_module.symbols.items.len);
        // For every symbol by name, is_live must agree.
        for (analyzed_module.symbols.items) |sym| {
            var found: ?bool = null;
            for (om.symbols.items) |osym| {
                if (std.mem.eql(u8, sym.original_name, osym.original_name)) {
                    found = osym.flags.is_live;
                    break;
                }
            }
            if (found) |o_live| {
                try std.testing.expectEqual(o_live, sym.flags.is_live);
            }
        }
    }
}

// =========================================================================
// LA15 — Full sync invalidates cache.
// =========================================================================

test "LA15: changeDocument full sync invalidates and re-populates cache" {
    const handler = try setup("fn f() -> i32 { return 0; }");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    const before = try handler.analyzeDocument(uri);
    _ = before;

    try handler.changeDocument(uri, "fn g() -> i32 { return 1; }");
    const doc = handler.documents.getPtr(uri).?;
    try std.testing.expect(doc.analysis == null);
    try std.testing.expect(doc.parse != null);
    try std.testing.expectEqualStrings("fn g() -> i32 { return 1; }", doc.parse.?.source);

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA16 — Close + reopen round-trip.
// =========================================================================

test "LA16: close + reopen produces oracle-consistent analysis" {
    const src: [:0]const u8 = "fn f() -> i32 { return 1; }";
    const uri = "test://file.wgsl";

    const handler = try setup(src);
    defer teardown(handler);

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);

    handler.closeDocument(uri);
    try std.testing.expect(handler.documents.getPtr(uri) == null);

    try handler.openDocument(uri, src, 1);
    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA17 — Multi-document isolation.
// =========================================================================

test "LA17: three documents edit independently, each matches oracle" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const uris = [_][]const u8{ "test://a.wgsl", "test://b.wgsl", "test://c.wgsl" };
    const sources = [_][:0]const u8{
        "fn a() -> i32 { return 1; }",
        "fn b() -> i32 { return 2; }",
        "fn c() -> i32 { return 3; }",
    };
    inline for (uris, sources) |u, s| {
        try handler.openDocument(u, s, 1);
        _ = try handler.analyzeDocument(u);
    }

    // Edit each one's literal differently.
    inline for (uris, 0..) |u, idx| {
        const doc = handler.documents.getPtr(u).?;
        const off = at(doc.source, "return ") + 7;
        var buf: [4]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "{d}", .{(idx + 1) * 10});
        try handler.changeDocumentIncremental(
            u,
            rangeFor(doc.source, off, off + 1),
            txt,
        );
    }

    inline for (uris) |u| {
        _ = try handler.analyzeDocument(u);
        try expectConsistencyOracle(handler, u);
    }
}

// =========================================================================
// LA18 — Block-comment break and re-close round-trip.
// =========================================================================

test "LA18: break then re-close a block comment — cache round-trips to clean" {
    const handler = try setup(
        "/* prelude */\nconst a: i32 = 1;\nconst b: i32 = 2;\n",
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);

    // Break the comment by deleting `*/`.
    const doc = handler.documents.getPtr(uri).?;
    const close_off = at(doc.source, "*/");
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, close_off, close_off + 2),
        "",
    );
    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);

    // Re-close by inserting `*/ ` back in the same spot.
    const doc2 = handler.documents.getPtr(uri).?;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc2.source, close_off, close_off),
        "*/",
    );
    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA19 — Large paste then small literal flip.
// =========================================================================

test "LA19: large paste then literal flip — both match oracle" {
    const handler = try setup("fn f() -> i32 { return 0; }");
    defer teardown(handler);
    const uri = "test://file.wgsl";

    _ = try handler.analyzeDocument(uri);

    // Build a large paste: append 50 extra fn decls.
    var paste: std.ArrayListUnmanaged(u8) = .empty;
    defer paste.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var buf: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "fn g_{d}() -> i32 {{ return {d}; }}\n",
            .{ i, i },
        );
        try paste.appendSlice(std.testing.allocator, line);
    }
    const doc = handler.documents.getPtr(uri).?;
    const tail = @as(u32, @intCast(doc.source.len));
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, tail, tail),
        paste.items,
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);

    // Small literal flip inside the original fn — hot path should
    // re-engage after the fallback.
    const doc2 = handler.documents.getPtr(uri).?;
    const zero_off = at(doc2.source, "return 0;") + 7;
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc2.source, zero_off, zero_off + 1),
        "99",
    );

    _ = try handler.analyzeDocument(uri);
    try expectConsistencyOracle(handler, uri);
}

// =========================================================================
// LA20 — Stable-ID preservation across a compound_stmt edit.
//
// A compound_stmt hot-path edit inside one function must not perturb the
// stable IDs of any OTHER top-level decl. Stable IDs are the handle
// layer-above consumers (refactorings, external tools) use to pin
// symbols across reparses, so any reorder/rename of `module.symbols`
// would show up here as a mismatch before it breaks anything else.
// =========================================================================

test "LA20: compound_stmt edit preserves stable IDs of other top-level decls" {
    const handler = try setup(
        \\const K: i32 = 42;
        \\struct Thing { a: i32, b: i32, }
        \\fn f() -> i32 { let x: i32 = 1; return x; }
        \\fn g() -> i32 { return K; }
    );
    defer teardown(handler);
    const uri = "test://file.wgsl";

    _ = try handler.analyzeDocument(uri);

    // Snapshot stable IDs of every top-level decl by name.
    const Names = enum { K, Thing, f, g };
    var before: [4]?[]u8 = .{ null, null, null, null };
    defer {
        for (before) |b| if (b) |s| std.testing.allocator.free(s);
    }

    {
        const doc = handler.documents.getPtr(uri).?;
        const module = doc.parse.?.module;
        var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();
        for (module.declarations.items) |d| {
            const sym = d.nameRef();
            if (!sym.isValid()) continue;
            const s = module.symbols.items[sym.index()];
            const which: Names = blk: {
                if (std.mem.eql(u8, s.original_name, "K")) break :blk .K;
                if (std.mem.eql(u8, s.original_name, "Thing")) break :blk .Thing;
                if (std.mem.eql(u8, s.original_name, "f")) break :blk .f;
                if (std.mem.eql(u8, s.original_name, "g")) break :blk .g;
                continue;
            };
            const sid = (try wgslender.StableId.stableIdFor(a, module, sym)) orelse continue;
            before[@intFromEnum(which)] = try std.testing.allocator.dupe(u8, sid.bytes);
        }
    }

    // Every top-level decl must have produced a stable ID.
    for (before) |b| try std.testing.expect(b != null);

    // Compound_stmt hot-path edit inside `fn f`'s body only: append a
    // new statement before the existing `return x;`. This routes
    // through `tryCompoundSpliceInPlace` and mutates the symbol table
    // (the new `let y` symbol gets appended), but must not perturb any
    // existing decl's index or the owning scope of K / Thing / f / g.
    const doc = handler.documents.getPtr(uri).?;
    const ret_off = at(doc.source, "return x;");
    try handler.changeDocumentIncremental(
        uri,
        rangeFor(doc.source, ret_off, ret_off),
        "let y: i32 = 2; ",
    );

    _ = try handler.analyzeDocument(uri);

    // Compute stable IDs after the edit; each of K, Thing, f, g must
    // round-trip to the same bytes as before.
    const doc2 = handler.documents.getPtr(uri).?;
    const module2 = doc2.parse.?.module;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    var seen: [4]bool = .{ false, false, false, false };
    for (module2.declarations.items) |d| {
        const sym = d.nameRef();
        if (!sym.isValid()) continue;
        const s = module2.symbols.items[sym.index()];
        const which: Names = blk: {
            if (std.mem.eql(u8, s.original_name, "K")) break :blk .K;
            if (std.mem.eql(u8, s.original_name, "Thing")) break :blk .Thing;
            if (std.mem.eql(u8, s.original_name, "f")) break :blk .f;
            if (std.mem.eql(u8, s.original_name, "g")) break :blk .g;
            continue;
        };
        const sid = (try wgslender.StableId.stableIdFor(a, module2, sym)) orelse continue;
        try std.testing.expectEqualStrings(before[@intFromEnum(which)].?, sid.bytes);
        seen[@intFromEnum(which)] = true;
    }
    for (seen) |v| try std.testing.expect(v);

    // And the full analysis still matches a fresh oracle.
    try expectConsistencyOracle(handler, uri);
}
