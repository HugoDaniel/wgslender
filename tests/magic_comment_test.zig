//! Tests for `MagicComment.scan` — per-document directive parser that
//! produces a `MinifySettings.Partial` layer (highest precedence in the
//! resolver) plus M0000 diagnostics for unrecognised directives.

const std = @import("std");
const wgslender = @import("wgslender");
const MagicComment = wgslender.MagicComment;
const MinifySettings = wgslender.MinifySettings;
const Diagnostic = wgslender.Diagnostic;

fn scan(arena: std.mem.Allocator, source: []const u8) !MagicComment.ScanResult {
    return MagicComment.scan(arena, source);
}

test "scan: wgslender-minify-insights shorthand → mode=insights" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-insights\nfn main() {}\n");
    try std.testing.expectEqual(MinifySettings.Mode.insights, result.partial.mode.?);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: wgslender-minify-strict shorthand → mode=strict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-strict\n");
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: wgslender-minify-mode=insights" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-mode=insights\n");
    try std.testing.expectEqual(MinifySettings.Mode.insights, result.partial.mode.?);
}

test "scan: wgslender-minify-mode=strict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-mode=strict\n");
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
}

test "scan: wgslender-minify-mode=off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-mode=off\n");
    try std.testing.expectEqual(MinifySettings.Mode.off, result.partial.mode.?);
}

test "scan: block comment form accepted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "/* wgslender-minify-mode=strict */\n");
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: block comment form with shorthand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "/* wgslender-minify-insights */\n");
    try std.testing.expectEqual(MinifySettings.Mode.insights, result.partial.mode.?);
}

test "scan: last directive wins on conflict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\// wgslender-minify-insights
        \\// wgslender-minify-mode=strict
        \\fn main() {}
    ;
    const result = try scan(arena_state.allocator(), src);
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
}

test "scan: multiple directives in separate comments accumulate, last wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\// wgslender-minify-mode=off
        \\fn a() {}
        \\// wgslender-minify-strict
        \\fn b() {}
    ;
    const result = try scan(arena_state.allocator(), src);
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
}

test "scan: unknown directive → M0000 diagnostic, partial unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-nonsense\n");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqualStrings("M0000", result.diagnostics[0].code);
    try std.testing.expectEqualStrings("minify", result.diagnostics[0].spec_ref);
    try std.testing.expectEqual(Diagnostic.Severity.warning, result.diagnostics[0].severity);
}

test "scan: unknown mode value → M0000, partial unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// wgslender-minify-mode=loud\n");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqualStrings("M0000", result.diagnostics[0].code);
}

test "scan: case-sensitive — capitalised directives are ignored silently" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// Wgslender-Minify-Insights\n");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: whitespace around '=' permitted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "//   wgslender-minify-mode   =   strict\n");
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
}

test "scan: directive inside WGSL nested block comment still parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\/* outer /* wgslender-minify-strict */ tail */
        \\fn main() {}
    ;
    const result = try scan(arena_state.allocator(), src);
    try std.testing.expectEqual(MinifySettings.Mode.strict, result.partial.mode.?);
}

test "scan: directive placed deep in file still found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\fn a() {}
        \\fn b() {}
        \\// wgslender-minify-insights
        \\fn c() {}
    ;
    const result = try scan(arena_state.allocator(), src);
    try std.testing.expectEqual(MinifySettings.Mode.insights, result.partial.mode.?);
}

test "scan: no directive → empty Partial, no diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(),
        \\// just a plain comment
        \\/* another one */
        \\fn main() {}
    );
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: lookalike substring inside identifier does not match" {
    // `my-wgslender-minify-strict` is preceded by `-`, which is part of
    // the same token — it shouldn't trigger a directive.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "// prefix-wgslender-minify-strict\n");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: directive at end of 256KB of filler still found (linear scan)" {
    // Wall-clock timing is deferred until Zig 0.16 exposes std.time.Timer
    // (same note lives in lsp_incremental_compound_perf_test.zig). The
    // correctness shape here — "directive survives at high filler ratio" —
    // catches regressions that would turn the scan into O(N²) via
    // accidental re-scanning of the same prefix on every comment.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const filler_line = "// plain commentary with no minify directive here\n";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const target: usize = 256 * 1024;
    while (buf.items.len < target) try buf.appendSlice(a, filler_line);
    try buf.appendSlice(a, "// wgslender-minify-insights\n");

    const result = try scan(a, buf.items);
    try std.testing.expectEqual(MinifySettings.Mode.insights, result.partial.mode.?);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "specRefFor: M-prefix maps to minify slug" {
    try std.testing.expectEqualStrings("minify", Diagnostic.specRefFor("M0000"));
    try std.testing.expectEqualStrings("minify", Diagnostic.specRefFor("M0100"));
    try std.testing.expectEqualStrings("minify", Diagnostic.specRefFor("M0599"));
}

test "Code.unknown_minify_directive has value M0000" {
    try std.testing.expectEqualStrings("M0000", Diagnostic.Code.unknown_minify_directive);
}
