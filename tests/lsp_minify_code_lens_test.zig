//! Phase 6 — module-level total-size code lens + showMinifiedOutput command.
//!
//! The lens is emitted by `Handler.computeCodeLens` at line 0 whenever
//! the document's resolved minify-mode requests `insights.totalSize`
//! (default-on for `mode=insights|strict`, off for `mode=off`). Title
//! shape: `"<src> B → <min> B min → <gz> B gz"`, with a
//! ` (over budget)` ASCII suffix when the resolved
//! `minifyLints.budgetBytes` is exceeded by the estimator.
//!
//! Click target: `wgslender.server.showMinifiedOutput`, which delegates to
//! `Handler.runShowMinifiedOutput` and returns the full minified text
//! plus byte/gz counts so the client can spawn a virtual document.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");

fn setup() !*Handler {
    const h = try std.testing.allocator.create(Handler);
    h.* = Handler.init(std.testing.allocator);
    return h;
}

fn teardown(h: *Handler) void {
    h.deinit();
    std.testing.allocator.destroy(h);
}

fn parseJson(json: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true, .max_value_len = null },
    );
}

fn applySettings(h: *Handler, json: []const u8) !void {
    var parsed = try parseJson(json);
    defer parsed.deinit();
    h.applyClientConfig(parsed.value);
}

fn freeLenses(lenses: []const Handler.CodeLensInfo) void {
    Handler.freeCodeLens(std.testing.allocator, lenses);
}

/// Locate the module-level total-size lens — the one anchored at line
/// 0, character 0, with the `wgslender.server.showMinifiedOutput` click
/// command. Returns null if no such lens was emitted.
fn findTotalLens(lenses: []const Handler.CodeLensInfo) ?Handler.CodeLensInfo {
    for (lenses) |l| {
        if (l.range.start.line != 0 or l.range.start.character != 0) continue;
        if (l.command) |c| {
            if (std.mem.eql(u8, c, "wgslender.server.showMinifiedOutput")) return l;
        }
    }
    return null;
}

const sample_shader: [:0]const u8 =
    \\fn helper_one() -> f32 { return 1.0; }
    \\fn helper_two() -> f32 { return 2.0; }
    \\@compute @workgroup_size(1) fn main() {
    \\    let _v = helper_one() + helper_two();
    \\}
;

// =========================================================================
// Lens visibility — gated on resolved insights.totalSize
// =========================================================================

test "code lens: no total-size lens when mode=off (default)" {
    const h = try setup();
    defer teardown(h);
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    try std.testing.expect(findTotalLens(lenses) == null);
}

test "code lens: total-size lens at line 0 when mode=insights" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse {
        std.debug.print("expected total-size lens at mode=insights, found {d} lenses\n", .{lenses.len});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u32, 0), lens.range.start.line);
    try std.testing.expectEqual(@as(u32, 0), lens.range.start.character);
    try std.testing.expectEqual(@as(u32, 0), lens.range.end.line);
    try std.testing.expectEqual(@as(u32, 0), lens.range.end.character);
}

test "code lens: total-size lens at line 0 when mode=strict" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    try std.testing.expect(findTotalLens(lenses) != null);
}

test "code lens: insights.totalSize=false suppresses total-size lens" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"totalSize":false}}}
    );
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    try std.testing.expect(findTotalLens(lenses) == null);
}

// =========================================================================
// Title format
// =========================================================================

test "code lens: title shows 'NN B → NN B min → NN B gz'" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    // Three " B " separators: "<src> B → <min> B min → <gz> B gz".
    // Asserting on " B " count + the two arrows pins the format
    // without locking specific byte counts.
    try std.testing.expect(std.mem.indexOf(u8, lens.title, " B \u{2192} ") != null);
    try std.testing.expect(std.mem.indexOf(u8, lens.title, " B min \u{2192} ") != null);
    try std.testing.expect(std.mem.endsWith(u8, lens.title, " B gz"));
}

// =========================================================================
// Click command: wgslender.server.showMinifiedOutput
// =========================================================================

test "code lens: click target is wgslender.server.showMinifiedOutput" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    const cmd = lens.command orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wgslender.server.showMinifiedOutput", cmd);
}

test "code lens: command argument is the document URI" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    const args = lens.arguments orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), args.len);
    switch (args[0]) {
        .string => |s| try std.testing.expectEqualStrings("file:///a.wgsl", s),
        else => return error.TestUnexpectedResult,
    }
}

// =========================================================================
// runShowMinifiedOutput — the command handler
// =========================================================================

test "runShowMinifiedOutput: returns minified text + byte counts for known URI" {
    const h = try setup();
    defer teardown(h);
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try h.runShowMinifiedOutput(arena.allocator(), "file:///a.wgsl");

    try std.testing.expectEqualStrings("file:///a.wgsl", result.uri);
    try std.testing.expect(result.minified_text.len > 0);
    // Minified output must be strictly smaller than the source for a
    // shader with whitespace + comments. (sample_shader has both.)
    try std.testing.expect(result.minified_text.len < sample_shader.len);
    try std.testing.expect(result.byte_count > 0);
    try std.testing.expect(result.gz_count > 0);
    // The estimator's gz heuristic is `total_min * 0.35`, so gz must be
    // strictly less than min for any non-trivial output.
    try std.testing.expect(result.gz_count < result.byte_count);
}

test "runShowMinifiedOutput: unknown URI errors with DocumentNotFound" {
    const h = try setup();
    defer teardown(h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.DocumentNotFound,
        h.runShowMinifiedOutput(arena.allocator(), "file:///nonexistent.wgsl"),
    );
}

test "runShowMinifiedOutput: byte_count matches lens title number" {
    // Pin the parity contract from §6.2 of the plan: the lens displays
    // estimator output, and so does the command response. Re-deriving
    // numbers client-side would be redundant — both must agree.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);
    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try h.runShowMinifiedOutput(arena.allocator(), "file:///a.wgsl");

    var buf: [32]u8 = undefined;
    const min_str = try std.fmt.bufPrint(&buf, "{d} B min", .{result.byte_count});
    try std.testing.expect(std.mem.indexOf(u8, lens.title, min_str) != null);
}

// =========================================================================
// didChange invalidates the lens
// =========================================================================

test "code lens: total-size lens updates after didChange" {
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", "fn a() {}\n", 1);

    const before = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(before);
    const lens_before = findTotalLens(before) orelse return error.TestUnexpectedResult;
    const title_before = try std.testing.allocator.dupe(u8, lens_before.title);
    defer std.testing.allocator.free(title_before);

    // Replace with a much larger source — the title must change.
    try h.changeDocument("file:///a.wgsl", sample_shader);

    const after = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(after);
    const lens_after = findTotalLens(after) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, title_before, lens_after.title));
}

// =========================================================================
// Invalid syntax: estimator bails, no panic
// =========================================================================

test "code lens: total-size path does not panic on syntactically invalid source" {
    // Spec contract (per master-plan §9.1): the lens path tolerates
    // malformed input. The parser is recovery-friendly and may still
    // produce a partial module here, in which case the estimator can
    // run and we get a lens with degraded numbers — that's fine. The
    // load-bearing claim is "no panic, well-formed title shape if
    // emitted, allocator clean".
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///bad.wgsl", "fn broken(", 1);

    const lenses = try h.computeCodeLens("file:///bad.wgsl");
    defer freeLenses(lenses);

    if (findTotalLens(lenses)) |lens| {
        try std.testing.expect(std.mem.indexOf(u8, lens.title, " B \u{2192} ") != null);
        try std.testing.expect(std.mem.endsWith(u8, lens.title, " B gz") or
            std.mem.endsWith(u8, lens.title, " B gz (over budget)"));
    }
}

// =========================================================================
// Over-budget badge — depends on minifyLints.budgetBytes
// =========================================================================

test "code lens: over-budget badge appears when total_min > budgetBytes" {
    const h = try setup();
    defer teardown(h);
    // Tiny budget guarantees the multi-decl shader exceeds it.
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"enabled":true,"budgetBytes":1}}}
    );
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, lens.title, " (over budget)"));
}

test "code lens: no badge when total_min <= budgetBytes" {
    const h = try setup();
    defer teardown(h);
    // 1 MiB ceiling — no realistic test fixture brushes against it.
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"enabled":true,"budgetBytes":1048576}}}
    );
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.endsWith(u8, lens.title, " (over budget)"));
}

test "code lens: no badge when budgetBytes unset (tri-state preserved)" {
    const h = try setup();
    defer teardown(h);
    // Strict mode + lints on, no budget — over-budget logic must not
    // engage. This pins the ?u32 tri-state contract: missing != 0.
    try applySettings(h,
        \\{"lsp":{"minifyMode":"strict","minifyLints":{"enabled":true}}}
    );
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    const lens = findTotalLens(lenses) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.endsWith(u8, lens.title, " (over budget)"));
}

test "code lens: existing reference / workgroup lenses still emit alongside total-size" {
    // Phase 6 must not regress the prior code-lens output. Confirm the
    // reference-count and workgroup lenses are still present at their
    // expected positions while the new total-size lens sits at line 0.
    const h = try setup();
    defer teardown(h);
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");
    try h.openDocument("file:///a.wgsl", sample_shader, 1);

    const lenses = try h.computeCodeLens("file:///a.wgsl");
    defer freeLenses(lenses);

    try std.testing.expect(findTotalLens(lenses) != null);

    var saw_reference_lens = false;
    var saw_workgroup_lens = false;
    for (lenses) |l| {
        if (std.mem.indexOf(u8, l.title, "reference") != null) saw_reference_lens = true;
        if (std.mem.indexOf(u8, l.title, "workgroup:") != null) saw_workgroup_lens = true;
    }
    try std.testing.expect(saw_reference_lens);
    try std.testing.expect(saw_workgroup_lens);
}
