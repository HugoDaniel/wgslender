//! Leading module-scope directive scanning for assembled WGSL
//! (pngine-shaders phase 02, Task 2).
//!
//! WGSL admits `enable`, `requires` and module-scope `diagnostic`
//! directives before the first declaration and nowhere else. Assembly
//! puts other parts' declarations above a part's own text, so each
//! part's leading directives are lifted to the assembled module's first
//! lines and blanked where they were written. This module is the pure
//! scanner half: it finds that leading region, skips nested comments,
//! and compares directive spellings the way pngine does.
//!
//! Mirrors `scanDirectives` / `skipTrivia` / `scanToSemicolon` /
//! `directiveEql` in `pngine/src/dsl_sjon/fragments.zig`. No allocation
//! besides the output list, no recursion, no I/O: the same module is
//! compiled inside pngine's test process for the Task 5 parity gate.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Module-scope directives hoisted into one assembled module. pngine's
/// `MAX_DIRECTIVES`; duplicates count against the bound there, and here.
pub const MAX_DIRECTIVES: u32 = 64;

pub const Error = error{
    /// More than `MAX_DIRECTIVES` directives across the parts scanned so
    /// far. Reported rather than silently truncating the 65th.
    TooManyDirectives,
    OutOfMemory,
};

/// One directive found in a part's leading region.
pub const Directive = struct {
    /// The directive itself, from keyword through the terminating `;`.
    /// Borrowed from that part's text; comments inside it are included.
    text: []const u8,
    /// Byte span in the part's text, which blanking overwrites.
    start: usize,
    end: usize,
    /// 1-based line of `start` in the part's own text.
    line: u32,
    /// How many lines the directive spans there. At least one.
    lines: u32,
};

/// Append `text`'s leading directives to `out`.
///
/// `limit` is how many directives may still be appended globally. The
/// caller passes `MAX_DIRECTIVES - already_hoisted`; a part with more
/// than that reports `TooManyDirectives` on the one that would cross the
/// cap. `out` holds this part's directives only.
///
/// A directive with no terminating `;` is left where it was written: it
/// is already invalid WGSL, and a hoist must not guess where it ended.
/// The first token that is not one of the three keywords ends the scan,
/// so a part with no directives costs one identifier read.
///
/// Complexity: O(leading trivia + directives). No recursion.
pub fn scan(
    gpa: Allocator,
    text: []const u8,
    out: *std.ArrayList(Directive),
    limit: u32,
) Error!void {
    var i: usize = 0;
    var line: u32 = 1;

    // Every iteration either appends a directive (bounded by `limit`) or
    // returns, so the iteration after the last possible append reports it.
    for (0..@as(usize, limit) + 1) |_| {
        i = skipTrivia(text, i, &line);
        if (i >= text.len) return;

        const kw_end = identEnd(text, i);
        if (kw_end == i) return; // punctuation or an attribute: a declaration
        if (!isDirectiveKeyword(text[i..kw_end])) return;

        const start = i;
        const start_line = line;
        const end = scanToSemicolon(text, kw_end, &line) orelse return;
        i = end;

        if (out.items.len >= limit) return error.TooManyDirectives;
        out.append(gpa, .{
            .text = text[start..end],
            .start = start,
            .end = end,
            .line = start_line,
            .lines = line - start_line + 1,
        }) catch return error.OutOfMemory;
    } else unreachable;
}

/// Are these the same directive, ignoring whitespace?
///
/// `enable  f16;` and `enable f16;` are one directive written twice, and
/// only the first is hoisted. Comments inside a directive defeat it, as
/// pngine's rule intends: two spellings that differ only by a comment
/// are hoisted twice, which WGSL diagnoses for `diagnostic`.
pub fn eql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    for (0..a.len + 1) |_| {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    } else unreachable;
}

fn isDirectiveKeyword(token: []const u8) bool {
    const keywords = std.StaticStringMap(void).initComptime(.{
        .{ "enable", {} },
        .{ "requires", {} },
        .{ "diagnostic", {} },
    });
    return keywords.has(token);
}

/// End of the identifier starting at `from`, or `from` when there is
/// none. pngine's WGSL identifiers are ASCII: letter or `_`, then
/// alphanumeric or `_`.
fn identEnd(text: []const u8, from: usize) usize {
    if (from >= text.len) return from;
    const first = text[from];
    if (!std.ascii.isAlphabetic(first) and first != '_') return from;
    var i = from + 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
    return i;
}

/// Index just past the `;` that ends a directive, or null when the text
/// runs out first. Comments are skipped rather than searched, so a `;`
/// inside one does not end the directive early.
fn scanToSemicolon(text: []const u8, from: usize, line: *u32) ?usize {
    var i = from;
    while (i < text.len) {
        const c = text[i];
        if (c == ';') return i + 1;
        if (c == '/' and i + 1 < text.len and (text[i + 1] == '/' or text[i + 1] == '*')) {
            const next = skipTrivia(text, i, line);
            std.debug.assert(next > i);
            i = next;
            continue;
        }
        if (c == '\n') line.* += 1;
        i += 1;
    }
    return null;
}

/// Skip whitespace and comments from `from`, counting the newlines
/// crossed. WGSL block comments nest, so this is not a search for `*/`.
///
/// `\r` is trivia (CRLF input); only `\n` advances the line counter, as
/// pngine counts lines.
fn skipTrivia(text: []const u8, from: usize, line: *u32) usize {
    var i = from;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            line.* += 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c != '/' or i + 1 >= text.len) break;
        if (text[i + 1] == '/') {
            i += 2;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (text[i + 1] == '*') {
            i += 2;
            var depth: u32 = 1;
            while (i < text.len and depth > 0) {
                if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else {
                    if (text[i] == '\n') line.* += 1;
                    i += 1;
                }
            }
            // An unterminated block comment swallows the rest of the
            // part, which is also what the WGSL compiler will do.
            continue;
        }
        break; // a lone '/' is division: a declaration has begun
    }
    std.debug.assert(i >= from); // post: never rewinds
    return i;
}
