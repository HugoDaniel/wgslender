//! `wgslender-minify-*` magic comments — per-document override of the
//! minifier-mode setting.
//!
//! Grammar (locked in §2.6 of the minifier-mode design note):
//!
//! ```wgsl
//! // wgslender-minify-mode=insights
//! // wgslender-minify-mode=strict
//! // wgslender-minify-mode=off
//! /* wgslender-minify-mode=strict */
//!
//! // Shorthands:
//! // wgslender-minify-insights
//! // wgslender-minify-strict
//! ```
//!
//! Rule-level disables (`wgslender-disable[-next-line|-line|-file]`) are
//! handled by `src/lint/Disable.zig`; this scanner is only responsible
//! for the mode directive.
//!
//! Contract:
//! * Single linear pass — comments are re-discovered the same way
//!   `src/lint/Disable.zig` finds them, so WGSL nested block comments
//!   work out of the box.
//! * Later directives override earlier ones (last-wins).
//! * Unknown directives emit an `M0000` diagnostic and leave the partial
//!   untouched — the resolver falls back to workspace / project / default.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("Diagnostic.zig");
const MinifySettings = @import("MinifySettings.zig");

pub const ScanResult = struct {
    /// Accumulated per-document layer. Fields left `null` defer to lower-
    /// precedence layers in `MinifySettings.resolve`.
    partial: MinifySettings.Partial = .{},
    /// M0000 diagnostics for unrecognised directives. Allocated on the
    /// arena passed to `scan`.
    diagnostics: []Diagnostic.Entry = &.{},
};

/// Scan `source` for magic-comment directives. All output (diagnostics
/// slice and any nested message strings) is allocated on `arena`.
pub fn scan(arena: Allocator, source: []const u8) Allocator.Error!ScanResult {
    var partial: MinifySettings.Partial = .{};
    var diags: std.ArrayListUnmanaged(Diagnostic.Entry) = .empty;

    var line: u32 = 1;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len) {
            const n = source[i + 1];
            if (n == '/') {
                const start = i;
                var end = i + 2;
                while (end < source.len and source[end] != '\n') : (end += 1) {}
                try scanComment(arena, &partial, &diags, source[start..end], @intCast(start), line);
                i = end;
                continue;
            }
            if (n == '*') {
                // WGSL nests block comments — track depth and skip in one
                // hop so a nested directive inside the outer block is still
                // picked up by `scanComment`.
                const start = i;
                var end = i + 2;
                var depth: u32 = 1;
                var line_bumps: u32 = 0;
                while (end < source.len and depth > 0) {
                    const ch = source[end];
                    if (ch == '\n') line_bumps += 1;
                    if (ch == '/' and end + 1 < source.len and source[end + 1] == '*') {
                        depth += 1;
                        end += 2;
                        continue;
                    }
                    if (ch == '*' and end + 1 < source.len and source[end + 1] == '/') {
                        depth -= 1;
                        end += 2;
                        continue;
                    }
                    end += 1;
                }
                try scanComment(arena, &partial, &diags, source[start..end], @intCast(start), line);
                line += line_bumps;
                i = end;
                continue;
            }
        }
        i += 1;
    }

    return .{ .partial = partial, .diagnostics = try diags.toOwnedSlice(arena) };
}

const directive_prefix = "wgslender-minify-";

fn scanComment(
    arena: Allocator,
    partial: *MinifySettings.Partial,
    diags: *std.ArrayListUnmanaged(Diagnostic.Entry),
    comment_text: []const u8,
    loc: u32,
    line: u32,
) Allocator.Error!void {
    const body = stripDelimiters(comment_text);
    var search_from: usize = 0;
    while (search_from + directive_prefix.len <= body.len) {
        const hit = std.mem.indexOfPos(u8, body, search_from, directive_prefix) orelse break;
        // Word-boundary check: the prefix must not be fused onto an
        // identifier-like token to its left ("foo-wgslender-minify-strict"
        // is a plain comment, not a directive).
        const at_boundary = hit == 0 or !isWordChar(body[hit - 1]);
        if (!at_boundary) {
            search_from = hit + 1;
            continue;
        }
        // Directive runs until newline, end-of-comment, or the closing
        // `*/` of a block comment.
        var end = hit + directive_prefix.len;
        while (end < body.len) : (end += 1) {
            const ch = body[end];
            if (ch == '\n' or ch == '\r') break;
            if (ch == '*' and end + 1 < body.len and body[end + 1] == '/') break;
        }
        try applyDirective(arena, partial, diags, body[hit..end], loc, line);
        search_from = end;
    }
}

fn applyDirective(
    arena: Allocator,
    partial: *MinifySettings.Partial,
    diags: *std.ArrayListUnmanaged(Diagnostic.Entry),
    text: []const u8,
    loc: u32,
    line: u32,
) Allocator.Error!void {
    // Caller guarantees `text` starts with `directive_prefix`.
    const tail = std.mem.trim(u8, text[directive_prefix.len..], " \t");

    // Shorthand forms: `wgslender-minify-insights` / `wgslender-minify-strict`.
    if (std.mem.eql(u8, tail, "insights")) {
        partial.mode = .insights;
        return;
    }
    if (std.mem.eql(u8, tail, "strict")) {
        partial.mode = .strict;
        return;
    }

    // Long form: `wgslender-minify-mode = <value>` (whitespace around `=`
    // permitted, per §2.6).
    if (std.mem.startsWith(u8, tail, "mode")) {
        const after_key = tail[4..];
        // Must be followed by `=` (optionally preceded by whitespace) —
        // otherwise this is an unrelated identifier like `mode_extra`.
        const after_ws = std.mem.trimStart(u8, after_key, " \t");
        if (after_ws.len > 0 and after_ws[0] == '=') {
            const value = std.mem.trim(u8, after_ws[1..], " \t");
            if (MinifySettings.Mode.fromString(value)) |m| {
                partial.mode = m;
                return;
            }
        }
    }

    try emitUnknown(arena, diags, loc, line, text);
}

fn emitUnknown(
    arena: Allocator,
    diags: *std.ArrayListUnmanaged(Diagnostic.Entry),
    loc: u32,
    line: u32,
    text: []const u8,
) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        arena,
        "unknown wgslender minify directive: '{s}'",
        .{text},
    );
    const end_loc = loc + @as(u32, @intCast(text.len));
    try diags.append(arena, .{
        .severity = .warning,
        .code = Diagnostic.Code.unknown_minify_directive,
        .message = msg,
        .spec_ref = "minify",
        .source = "wgslender-minify",
        .range = .{
            .start = .{ .offset = loc, .line = line, .column = 1 },
            .end = .{ .offset = end_loc, .line = line, .column = 1 },
        },
    });
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '-';
}

fn stripDelimiters(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '/' and text[1] == '/') return text[2..];
    if (text.len >= 4 and text[0] == '/' and text[1] == '*') {
        const inner = text[2..];
        if (inner.len >= 2 and inner[inner.len - 2] == '*' and inner[inner.len - 1] == '/') {
            return inner[0 .. inner.len - 2];
        }
        return inner;
    }
    return text;
}

// =========================================================================
// Tests
// =========================================================================

test "scan: empty source yields empty partial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "scan: source with only code and no comments yields empty partial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try scan(arena_state.allocator(), "fn main() { let x = 1; }");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), result.partial.mode);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
