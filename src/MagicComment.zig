//! `wgslender-minify-*` magic comments — per-document override layer
//! for `MinifySettings.Partial`. The accepted long-form keys are derived
//! at comptime from `MinifySettings.partial_specs`: every spec whose
//! `json_override` starts with `"minify"` and whose `magic_comment` flag
//! is true contributes a directive.
//!
//! Grammar:
//!
//! ```wgsl
//! // Long form — <key> = <value>:
//! // wgslender-minify-mode=strict
//! // wgslender-minify-insights-format=bytes
//! // wgslender-minify-insights-function-size=true
//! // wgslender-minify-lints-enabled=true
//! // wgslender-minify-estimator-use-full-minify=true
//! /* wgslender-minify-mode=strict */
//!
//! // Shorthands (locked — bare mode tag, no `=`):
//! // wgslender-minify-insights      // ⇔ mode=insights
//! // wgslender-minify-strict        // ⇔ mode=strict
//! ```
//!
//! Long-form keys are derived from each spec's camel-dotted JSON path
//! by stripping the leading `"minify"` and lowercasing camel boundaries
//! into kebab-case (so `minifyInsights.functionSize` ↔
//! `insights-function-size`). Adding a new field to
//! `MinifySettings.Partial` automatically extends the directive surface.
//!
//! Specs that opt out via `magic_comment = false` (today: `budget_bytes`,
//! to mirror the JSON-only precedent for `severities`) stay JSON-only.
//!
//! Rule-level disables (`wgslender-disable[-next-line|-line|-file]`) are
//! handled by `src/lint/Disable.zig`; this scanner is only responsible
//! for `MinifySettings.Partial` overrides.
//!
//! Contract:
//! * Single linear pass — comments are re-discovered the same way
//!   `src/lint/Disable.zig` finds them, so WGSL nested block comments
//!   work out of the box.
//! * Later directives override earlier ones (last-wins).
//! * Unknown directives — unknown key, unparseable value, or a key that
//!   opted out via `magic_comment = false` — emit an `M0000` diagnostic
//!   and leave the partial untouched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("Diagnostic.zig");
const MinifySettings = @import("MinifySettings.zig");
const options = @import("options.zig");

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

    // Long form: `<key> = <value>` — match `<key>` against any spec
    // whose JSON path sits under the "minify" namespace (and is not
    // opted out via `magic_comment = false`). Whitespace around `=`
    // permitted (§2.6).
    if (std.mem.indexOfScalar(u8, tail, '=')) |eq_pos| {
        const raw_key = std.mem.trim(u8, tail[0..eq_pos], " \t");
        const value = std.mem.trim(u8, tail[eq_pos + 1 ..], " \t");
        inline for (MinifySettings.partial_specs) |spec| {
            const magic_key = comptime magicCommentKey(spec);
            if (magic_key.len > 0 and std.mem.eql(u8, raw_key, magic_key)) {
                if (try options.applyValue(spec, value, arena, partial)) return;
                // Key matched but value didn't parse (unknown enum tag,
                // non-integer, non-bool literal). Fall through to the
                // M0000 emitter so the user sees the typo.
                break;
            }
        }
        try emitUnknown(arena, diags, loc, line, text);
        return;
    }

    // Bare directive (no `=`): shorthand for the mode field only. These
    // are locked — auto-deriving from `Mode.fromString` would silently
    // grow `wgslender-minify-off` as a third shorthand, which the
    // current grammar deliberately omits.
    if (std.mem.eql(u8, tail, "insights")) {
        partial.mode = .insights;
        return;
    }
    if (std.mem.eql(u8, tail, "strict")) {
        partial.mode = .strict;
        return;
    }

    try emitUnknown(arena, diags, loc, line, text);
}

/// Comptime-derive the magic-comment key for `spec`. Returns an empty
/// slice when the spec is not directive-eligible — its `json_override`
/// is unset / outside the "minify" namespace, or `magic_comment = false`.
/// Otherwise returns the camel-dotted suffix lowercased into kebab-case
/// (e.g. `"minifyInsights.functionSize"` → `"insights-function-size"`).
fn magicCommentKey(comptime spec: options.OptionSpec) []const u8 {
    if (!spec.magic_comment) return "";
    const json = spec.json_override orelse return "";
    const prefix = "minify";
    if (!std.mem.startsWith(u8, json, prefix)) return "";
    return camelDottedToKebab(json[prefix.len..]);
}

/// Comptime: `"Mode"` → `"mode"`, `"Insights.format"` → `"insights-format"`,
/// `"Insights.functionSize"` → `"insights-function-size"`. Each `.` and
/// each interior uppercase letter introduces a `-` separator; consecutive
/// separators collapse (a leading `-` is suppressed).
fn camelDottedToKebab(comptime s: []const u8) []const u8 {
    return &CamelDottedToKebab(s).value;
}

fn CamelDottedToKebab(comptime s: []const u8) type {
    comptime var out_len: usize = 0;
    {
        var prev_was_sep = true;
        for (s) |c| {
            if (c == '.') {
                out_len += 1;
                prev_was_sep = true;
            } else if (c >= 'A' and c <= 'Z') {
                if (!prev_was_sep) out_len += 1;
                out_len += 1;
                prev_was_sep = false;
            } else {
                out_len += 1;
                prev_was_sep = false;
            }
        }
    }
    return struct {
        pub const value: [out_len]u8 = blk: {
            var buf: [out_len]u8 = undefined;
            var i: usize = 0;
            var prev_was_sep = true;
            for (s) |c| {
                if (c == '.') {
                    buf[i] = '-';
                    i += 1;
                    prev_was_sep = true;
                } else if (c >= 'A' and c <= 'Z') {
                    if (!prev_was_sep) {
                        buf[i] = '-';
                        i += 1;
                    }
                    buf[i] = c + 32;
                    i += 1;
                    prev_was_sep = false;
                } else {
                    buf[i] = c;
                    i += 1;
                    prev_was_sep = false;
                }
            }
            break :blk buf;
        };
    };
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
