//! LSP analyze perf smoke record (B4).
//!
//! Drives a keystroke burst against the LSP `Handler` and records how
//! many times `Lexer.tokenize` was invoked across the burst. Phase A
//! (commit `e4e989d`) wired `analyzeDocument` to consume `doc.parse`
//! directly instead of re-tokenizing through `analyzeWithOptions`; this
//! test pins that `analyzeDocument` contributes zero tokenize calls per
//! edit.
//!
//! The handler's `changeDocumentIncremental` calls
//! `Incremental.classifyEdit` once per edit to decide whether a cache
//! hit survives — that call tokenizes the old + new sources (2 per
//! edit) and is expected. The assertion bounds the total at
//! `2 × EDIT_COUNT + slop`: if someone reintroduces a tokenize path in
//! `analyzeDocument` (e.g. falling back to `analyzeWithOptions`) the
//! count blows past the bound and this test catches it.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const Lexer = wgslender.Lexer;

const EDIT_COUNT: u32 = 200;

fn readBridge(gpa: std.mem.Allocator) ![:0]u8 {
    const io = std.Options.debug_io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/testdata/compute.toys", .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, "bridge.wgsl", gpa, .unlimited);
    defer gpa.free(bytes);
    const z = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(z, bytes);
    return z;
}

test "LSP analyze perf: 200-keystroke burst calls Lexer.tokenize O(1) times" {
    const gpa = std.testing.allocator;

    const source = try readBridge(gpa);
    defer gpa.free(source);

    // Pick a stable in-body offset to edit: the open-brace of the first
    // function body in the file. Inserting single characters just
    // inside the `{` exercises `tryCompoundSpliceInPlace`.
    const brace_pos_usize = std.mem.indexOfScalar(u8, source, '{') orelse
        return error.BridgeHasNoFnBody;
    const brace_pos: u32 = @intCast(brace_pos_usize);
    // Insertion point: immediately after `{`.
    const insert_at: u32 = brace_pos + 1;

    const handler = try gpa.create(Handler);
    handler.* = Handler.init(gpa);
    defer {
        handler.deinit();
        gpa.destroy(handler);
    }

    const uri = "file:///bridge.wgsl";
    try handler.openDocument(uri, source, 1);

    // Baseline: consume whatever tokenize calls the initial open path
    // made (`parseFull` uses `tokenizeAll`, not `tokenize`, so this is
    // usually 0 — but capturing it makes the test robust to future
    // refactors that add a bounded opening-path tokenize).
    _ = try handler.analyzeDocument(uri);
    const baseline = Lexer.tokenize_count;

    var i: u32 = 0;
    while (i < EDIT_COUNT) : (i += 1) {
        const doc = handler.documents.getPtr(uri).?;
        // Offset `insert_at` is stable as long as edits are pure
        // insertions at that position — each new character pushes the
        // tail further back but never shifts the insertion point.
        const pos = offsetToPosition(doc.source, insert_at);
        const txt = [_]u8{' '};
        try handler.changeDocumentIncremental(uri, .{ .start = pos, .end = pos }, &txt);
        _ = try handler.analyzeDocument(uri);
    }

    const tokenize_during_burst = Lexer.tokenize_count - baseline;

    std.debug.print(
        "perf-smoke bridge.wgsl {d} keystrokes: Lexer.tokenize_count (burst)={d}\n",
        .{ EDIT_COUNT, tokenize_during_burst },
    );

    // Phase A wiring goal: `analyzeDocument` consumes `doc.parse`
    // directly; only `classifyEdit` may tokenize (once per edit →
    // 2 tokenize calls). A regression that resumes tokenizing in
    // `analyzeDocument` would triple this count at minimum.
    const expected_upper_bound: u64 = 2 * EDIT_COUNT + 16;
    try std.testing.expect(tokenize_during_burst <= expected_upper_bound);
}

fn offsetToPosition(source: []const u8, off: u32) Handler.Position {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < off and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}
