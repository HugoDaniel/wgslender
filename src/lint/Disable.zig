//! `wgslender-disable` pragma comments.
//!
//! Users silence specific rules on a line, range, or whole file via WGSL
//! comments:
//!
//! ```wgsl
//! // wgslender-disable-next-line no-unused-vars
//! fn tempHelper() {}
//!
//! let x = bigExpr(); // wgslender-disable-line no-magic-numbers
//!
//! /* wgslender-disable no-magic-numbers */
//! let a = 42;
//! let b = 99;
//! /* wgslender-enable no-magic-numbers */
//!
//! /* wgslender-disable-file naming-convention */
//! ```
//!
//! Rule ids are comma-separated. An empty rule list disables every lint
//! rule.
//!
//! Algorithm:
//!   1. Scan the source once, collecting directives with their line
//!      numbers (1-based) and kind.
//!   2. For each lint diagnostic, consult the directive set:
//!      * `disable-file`  → drop if rule matches any file-scope directive.
//!      * `disable-line`  → drop if diagnostic line == directive line.
//!      * `disable-next-line` → drop if diagnostic line == directive line + 1.
//!      * `disable` / `enable` → maintain a per-rule open/close range;
//!         drop if diagnostic line is inside an open range.
//!   3. Optionally produce an `unused-disable-directive` diagnostic
//!      (W0209) for directives that didn't match anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig");

pub const Kind = enum {
    disable_line,
    disable_next_line,
    disable,
    enable,
    disable_file,
};

pub const Directive = struct {
    kind: Kind,
    /// Line number where the directive appears (1-based).
    line: u32,
    /// Byte offset of the directive's opening token (`//`/`/*`). Used
    /// only for reporting `unused-disable-directive`.
    loc: u32,
    /// Rule ids this directive targets. Empty list means "all rules".
    rules: []const []const u8,
    /// Flipped to true when at least one diagnostic matched this
    /// directive. `reportUnused` consults this to flag dead directives.
    matched: bool = false,
};

pub const DirectiveList = struct {
    items: []Directive,

    pub fn deinit(self: *DirectiveList, arena: Allocator) void {
        _ = arena;
        _ = self;
    }
};

/// Scan `source` for wgslender-disable directives. Returns a flat list
/// keyed by line number. Allocates onto `arena`.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!DirectiveList {
    var out: std.ArrayListUnmanaged(Directive) = .empty;
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
                // Line comment runs to end-of-line.
                const start = i;
                var end = i + 2;
                while (end < source.len and source[end] != '\n') : (end += 1) {}
                try tryParseDirective(arena, &out, source[start..end], @intCast(start), line);
                i = end;
                continue;
            }
            if (n == '*') {
                // Block comment. WGSL allows nested /* */; track depth.
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
                try tryParseDirective(arena, &out, source[start..end], @intCast(start), line);
                line += line_bumps;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    return .{ .items = try out.toOwnedSlice(arena) };
}

fn tryParseDirective(
    arena: Allocator,
    out: *std.ArrayListUnmanaged(Directive),
    comment_text: []const u8,
    loc: u32,
    line: u32,
) Allocator.Error!void {
    // Strip the comment marker bytes so we can look for the directive word.
    const body = strip(comment_text);
    const trimmed = std.mem.trim(u8, body, " \t");

    const prefixes = [_]struct { s: []const u8, k: Kind }{
        .{ .s = "wgslender-disable-next-line", .k = .disable_next_line },
        .{ .s = "wgslender-disable-line", .k = .disable_line },
        .{ .s = "wgslender-disable-file", .k = .disable_file },
        .{ .s = "wgslender-disable", .k = .disable },
        .{ .s = "wgslender-enable", .k = .enable },
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, trimmed, p.s)) {
            // Must be followed by end-of-string or whitespace so that
            // `wgslender-disable` doesn't accidentally match
            // `wgslender-disable-file`.
            if (trimmed.len != p.s.len and !isSpace(trimmed[p.s.len])) continue;
            const rest = std.mem.trim(u8, trimmed[p.s.len..], " \t");
            const rules = try parseRuleList(arena, rest);
            try out.append(arena, .{
                .kind = p.k,
                .line = line,
                .loc = loc,
                .rules = rules,
            });
            return;
        }
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn strip(text: []const u8) []const u8 {
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

fn parseRuleList(arena: Allocator, rest: []const u8) Allocator.Error![]const []const u8 {
    var rules: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |piece| {
        const id = std.mem.trim(u8, piece, " \t");
        if (id.len == 0) continue;
        try rules.append(arena, id);
    }
    return rules.toOwnedSlice(arena);
}

/// True when `directive` applies to `rule_id`. Empty rule list matches
/// any rule (user wrote `// wgslender-disable-next-line` with no args).
fn matches(directive: *const Directive, rule_id: []const u8) bool {
    if (directive.rules.len == 0) return true;
    for (directive.rules) |id| {
        if (std.mem.eql(u8, id, rule_id)) return true;
    }
    return false;
}

/// Drop from `entries` every diagnostic silenced by at least one
/// directive. Returns a new slice on `arena` (the original list is
/// unchanged). Directives that matched at least one diagnostic have their
/// `matched` flag flipped so `reportUnused` can surface the rest.
///
/// `rule_id_of` maps a diagnostic code back to the rule id it came from;
/// callers with access to the lint registry can pass
/// `registry.byCode(code).?.meta.id`.
pub fn filter(
    arena: Allocator,
    entries: []const Diagnostic.Entry,
    directives: *DirectiveList,
    rule_id_of: *const fn (code: []const u8) ?[]const u8,
) Allocator.Error![]Diagnostic.Entry {
    var kept: std.ArrayListUnmanaged(Diagnostic.Entry) = .empty;
    for (entries) |entry| {
        const rule_id = rule_id_of(entry.code) orelse {
            // Non-lint diagnostic (validator); never silenced.
            try kept.append(arena, entry);
            continue;
        };

        if (isSilenced(directives, rule_id, entry.range.start.line)) continue;
        try kept.append(arena, entry);
    }
    return kept.toOwnedSlice(arena);
}

fn isSilenced(directives: *DirectiveList, rule_id: []const u8, line: u32) bool {
    // File-scope: any disable-file for this rule silences every line.
    for (directives.items) |*d| {
        if (d.kind == .disable_file and matches(d, rule_id)) {
            d.matched = true;
            return true;
        }
    }
    // Line-scoped: disable-line on same line OR disable-next-line on previous line.
    for (directives.items) |*d| {
        if (d.kind == .disable_line and d.line == line and matches(d, rule_id)) {
            d.matched = true;
            return true;
        }
        if (d.kind == .disable_next_line and d.line + 1 == line and matches(d, rule_id)) {
            d.matched = true;
            return true;
        }
    }
    // Block-scoped: `disable` … `enable` ranges. A diagnostic at `line`
    // is silenced if the last `disable` for its rule before `line` has
    // no matching `enable` between them.
    var disabled: bool = false;
    var last_disable: ?*Directive = null;
    for (directives.items) |*d| {
        if (d.line > line) break;
        if (d.kind == .disable and matches(d, rule_id)) {
            disabled = true;
            last_disable = d;
        } else if (d.kind == .enable and matches(d, rule_id)) {
            disabled = false;
        }
    }
    if (disabled) {
        if (last_disable) |ld| ld.matched = true;
        return true;
    }
    return false;
}

/// Produce `unused-disable-directive` (W0209) diagnostics for every
/// directive that never matched. Appends to `diags` — callers control
/// whether to include them in the output.
pub fn reportUnused(
    arena: Allocator,
    source: []const u8,
    directives: *const DirectiveList,
    diags: *std.ArrayListUnmanaged(Diagnostic.Entry),
) Allocator.Error!void {
    _ = source;
    for (directives.items) |d| {
        if (d.matched) continue;
        const msg = try std.fmt.allocPrint(arena, "unused wgslender-disable directive", .{});
        try diags.append(arena, .{
            .severity = .warning,
            .code = Diagnostic.Code.lint_unused_disable_directive,
            .message = msg,
            .source = "wgslender-lint",
            .range = .{
                .start = .{ .offset = d.loc, .line = d.line, .column = 1 },
                .end = .{ .offset = d.loc + 1, .line = d.line, .column = 2 },
            },
        });
    }
}

// =========================================================================
// Tests
// =========================================================================

test "parse: disable-next-line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a,
        \\// wgslender-disable-next-line no-unused-vars
        \\fn foo() {}
    );
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(Kind.disable_next_line, list.items[0].kind);
    try std.testing.expectEqualStrings("no-unused-vars", list.items[0].rules[0]);
    try std.testing.expectEqual(@as(u32, 1), list.items[0].line);
}

test "parse: disable-line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a, "let x = 42; // wgslender-disable-line no-magic-numbers\n");
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(Kind.disable_line, list.items[0].kind);
}

test "parse: disable/enable block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a,
        \\/* wgslender-disable no-magic-numbers */
        \\let a = 42;
        \\let b = 99;
        \\/* wgslender-enable no-magic-numbers */
    );
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(Kind.disable, list.items[0].kind);
    try std.testing.expectEqual(Kind.enable, list.items[1].kind);
}

test "parse: multiple rules in one directive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a, "// wgslender-disable-next-line no-unused-vars, no-magic-numbers\n");
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(usize, 2), list.items[0].rules.len);
    try std.testing.expectEqualStrings("no-unused-vars", list.items[0].rules[0]);
    try std.testing.expectEqualStrings("no-magic-numbers", list.items[0].rules[1]);
}

test "parse: disable-file distinct from disable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a, "// wgslender-disable-file naming-convention\n");
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(Kind.disable_file, list.items[0].kind);
}

test "parse: empty rule list means all rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a, "// wgslender-disable-next-line\nfn f() {}\n");
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].rules.len);
}

test "parse: non-directive comments are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list = try parse(a, "// just a regular comment\n/* another */\n");
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
