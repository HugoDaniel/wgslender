//! Phase 4 — Inlay hints emitted by the LSP when minifier-mode is
//! `insights` or `strict`. Verifies:
//!
//!   * mode gating (off → no minify hints);
//!   * label format: `delta`, `bytes`, `both`;
//!   * sub-switches: `functionSize`, `declSize`, `totalSize`;
//!   * coexistence with the existing type-inference inlay hints;
//!   * tooltip text mentions the word "approximate";
//!   * KB rollover at ≥ 1024 B;
//!   * `didChange` updates hints to match the new source;
//!   * syntactically invalid documents return without crashing
//!     (any type hints the analyser can still produce are allowed,
//!     no minify hints are produced).

const std = @import("std");
const Handler = @import("Handler");

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

fn fullRange(source: []const u8) Handler.Range {
    var line: u32 = 0;
    var col: u32 = 0;
    for (source) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = line, .character = col },
    };
}

fn collectMinifyHints(
    arena: std.mem.Allocator,
    hints: []const Handler.InlayHintInfo,
) ![]const Handler.InlayHintInfo {
    var out: std.ArrayListUnmanaged(Handler.InlayHintInfo) = .empty;
    for (hints) |h| {
        if (h.kind == .minify_size) try out.append(arena, h);
    }
    return out.toOwnedSlice(arena);
}

fn hasTypeHint(hints: []const Handler.InlayHintInfo) bool {
    for (hints) |h| {
        if (h.kind == .type_hint) return true;
    }
    return false;
}

fn findTotalHint(hints: []const Handler.InlayHintInfo) ?Handler.InlayHintInfo {
    for (hints) |h| {
        if (h.kind != .minify_size) continue;
        if (h.position.line == 0 and h.position.character == 0) return h;
    }
    return null;
}

// =========================================================================
// mode gating
// =========================================================================

test "minify inlay: no minify hints when mode=off" {
    const h = try setup();
    defer teardown(h);

    const source: [:0]const u8 = "fn main() { let some_long_name = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    for (hints) |hint| {
        try std.testing.expect(hint.kind != .minify_size);
    }
}

test "minify inlay: emits minify hints when mode=insights" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const source: [:0]const u8 =
        \\fn longish_function_name() {
        \\  let value = 1.0;
        \\}
    ;
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const minify_hints = try collectMinifyHints(arena.allocator(), hints);
    try std.testing.expect(minify_hints.len > 0);
}

test "minify inlay: emits minify hints when mode=strict" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"strict\"}}");

    const source: [:0]const u8 = "fn main() { let value = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const minify_hints = try collectMinifyHints(arena.allocator(), hints);
    try std.testing.expect(minify_hints.len > 0);
}

// =========================================================================
// hint placement
// =========================================================================

test "minify inlay: module-level total hint sits at line 0 column 0" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const source: [:0]const u8 = "fn main() { let value = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    const total = findTotalHint(hints) orelse return error.NoTotalHint;
    try std.testing.expectEqual(@as(u32, 0), total.position.line);
    try std.testing.expectEqual(@as(u32, 0), total.position.character);
}

test "minify inlay: function hint emitted at decl span end" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const source: [:0]const u8 = "fn solo() { let v = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var found = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        // Skip the module-level total hint at {0,0}.
        if (hint.position.line == 0 and hint.position.character == 0) continue;
        // Function decl ends at the closing `}` (column == source.len).
        try std.testing.expectEqual(@as(u32, 0), hint.position.line);
        try std.testing.expectEqual(@as(u32, source.len), hint.position.character);
        found = true;
    }
    try std.testing.expect(found);
}

test "minify inlay: per-decl hint emitted for non-function named decls" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    // A struct that is referenced from a uniform var so DCE keeps it alive.
    const source: [:0]const u8 =
        \\struct Foo { x: f32 }
        \\@group(0) @binding(0) var<uniform> u: Foo;
        \\@compute @workgroup_size(1) fn main() { let _v = u.x; }
    ;
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    // Expect at least one minify hint on line 0 (struct line) other than the
    // total hint at column 0.
    var struct_hint: bool = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        if (hint.position.line == 0 and hint.position.character == 0) continue;
        if (hint.position.line == 0) struct_hint = true;
    }
    try std.testing.expect(struct_hint);
}

// =========================================================================
// label format
// =========================================================================

test "minify inlay: format=delta labels start with '-' and end in 'B'" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"format":"delta"}}}
    );

    const source: [:0]const u8 = "fn main_with_long_name() { let some_long_value = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var seen = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        seen = true;
        try std.testing.expect(hint.label.len > 0);
        try std.testing.expectEqual(@as(u8, '-'), hint.label[0]);
        try std.testing.expectEqual(@as(u8, 'B'), hint.label[hint.label.len - 1]);
    }
    try std.testing.expect(seen);
}

test "minify inlay: format=bytes labels start with a digit and end in 'B'" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"format":"bytes"}}}
    );

    const source: [:0]const u8 = "fn main_with_long_name() { let some_long_value = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var seen = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        seen = true;
        try std.testing.expect(hint.label.len > 0);
        try std.testing.expect(std.ascii.isDigit(hint.label[0]));
        try std.testing.expectEqual(@as(u8, 'B'), hint.label[hint.label.len - 1]);
        // Sanity: no embedded delta marker.
        try std.testing.expect(std.mem.indexOf(u8, hint.label, "(-") == null);
    }
    try std.testing.expect(seen);
}

test "minify inlay: format=both labels include '(-' and end with 'B)'" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"format":"both"}}}
    );

    const source: [:0]const u8 = "fn main_with_long_name() { let some_long_value = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var seen = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        seen = true;
        try std.testing.expect(std.mem.indexOf(u8, hint.label, "(-") != null);
        try std.testing.expect(std.mem.endsWith(u8, hint.label, "B)"));
    }
    try std.testing.expect(seen);
}

// =========================================================================
// sub-switches
// =========================================================================

test "minify inlay: insights.functionSize=false hides function hints" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"functionSize":false}}}
    );

    const source: [:0]const u8 =
        \\const X = 1.0;
        \\@compute @workgroup_size(1) fn main() { let _v = X; }
    ;
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    // No minify hint should land on line 1 (the fn decl line).
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        try std.testing.expect(hint.position.line != 1);
    }
}

test "minify inlay: insights.declSize=false hides non-function decl hints" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"declSize":false}}}
    );

    const source: [:0]const u8 =
        \\struct Foo { x: f32 }
        \\@group(0) @binding(0) var<uniform> u: Foo;
        \\@compute @workgroup_size(1) fn main() { let _v = u.x; }
    ;
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    // Lines 0 (struct) and 1 (var) must carry no minify hint other than the
    // total at {0,0}. The fn-decl hint on line 2 is allowed.
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        if (hint.position.line == 0 and hint.position.character == 0) continue;
        try std.testing.expect(hint.position.line != 0);
        try std.testing.expect(hint.position.line != 1);
    }
}

test "minify inlay: insights.totalSize=false hides total hint" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"totalSize":false}}}
    );

    const source: [:0]const u8 = "fn main() { let v = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    try std.testing.expect(findTotalHint(hints) == null);
}

// =========================================================================
// coexistence + lifecycle
// =========================================================================

test "minify inlay: coexists with type-inference inlay hints" {
    const h = try setup();
    defer teardown(h);

    // Type annotations are opt-in; this test is exactly about both lanes
    // rendering together, so it turns both on.
    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\",\"inlayHints\":{\"typeAnnotations\":true}}}");

    const source: [:0]const u8 = "fn f() { let x = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const minify_hints = try collectMinifyHints(arena.allocator(), hints);

    try std.testing.expect(hasTypeHint(hints));
    try std.testing.expect(minify_hints.len > 0);
}

test "minify inlay: hints update after didChange" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const before: [:0]const u8 = "fn main() { let v = 1.0; }";
    try h.openDocument("file:///a.wgsl", before, 1);

    const before_hints = try h.computeInlayHints("file:///a.wgsl", fullRange(before));
    defer std.testing.allocator.free(before_hints);
    const before_total = findTotalHint(before_hints) orelse return error.NoTotalHint;
    const before_label = try std.testing.allocator.dupe(u8, before_total.label);
    defer std.testing.allocator.free(before_label);

    const after: [:0]const u8 =
        \\fn main_with_a_much_longer_name() {
        \\  let some_value = 1.0;
        \\  let other_value = 2.0;
        \\  let third_value = 3.0;
        \\}
    ;
    try h.changeDocument("file:///a.wgsl", after);

    const after_hints = try h.computeInlayHints("file:///a.wgsl", fullRange(after));
    defer std.testing.allocator.free(after_hints);
    const after_total = findTotalHint(after_hints) orelse return error.NoTotalHint;

    try std.testing.expect(!std.mem.eql(u8, before_label, after_total.label));
}

test "minify inlay: syntactically invalid document yields no minify hints" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    // Truncated body — parser bails before producing a full module.
    const source: [:0]const u8 = "fn broken( ";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    for (hints) |hint| {
        try std.testing.expect(hint.kind != .minify_size);
    }
}

// =========================================================================
// rollover + tooltip
// =========================================================================

test "minify inlay: KB rollover for >=1024 B values" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h,
        \\{"lsp":{"minifyMode":"insights","minifyInsights":{"format":"bytes"}}}
    );

    // Build a long chain of `let` decls so the minified output exceeds
    // 1024 bytes. 200 lets × ≈8 bytes each = ≈1.6 KB minified.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var src: std.ArrayListUnmanaged(u8) = .empty;
    try src.appendSlice(arena.allocator(), "fn big() {\n");
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const line = try std.fmt.allocPrint(
            arena.allocator(),
            "  let v{d} = {d}.0;\n",
            .{ i, i },
        );
        try src.appendSlice(arena.allocator(), line);
    }
    try src.appendSlice(arena.allocator(), "}\n");
    try src.append(arena.allocator(), 0);
    const source: [:0]const u8 = src.items[0 .. src.items.len - 1 :0];

    try h.openDocument("file:///a.wgsl", source, 1);
    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    const total = findTotalHint(hints) orelse return error.NoTotalHint;
    try std.testing.expect(std.mem.endsWith(u8, total.label, "KB"));
}

test "minify inlay: tooltip mentions 'approximate'" {
    const h = try setup();
    defer teardown(h);

    try applySettings(h, "{\"lsp\":{\"minifyMode\":\"insights\"}}");

    const source: [:0]const u8 = "fn main() { let v = 1.0; }";
    try h.openDocument("file:///a.wgsl", source, 1);

    const hints = try h.computeInlayHints("file:///a.wgsl", fullRange(source));
    defer std.testing.allocator.free(hints);

    var seen = false;
    for (hints) |hint| {
        if (hint.kind != .minify_size) continue;
        seen = true;
        const tip = hint.tooltip orelse return error.MissingTooltip;
        try std.testing.expect(std.mem.indexOf(u8, tip, "approximate") != null);
    }
    try std.testing.expect(seen);
}
