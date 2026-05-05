//! Code Actions: generate quickfix edits in response to diagnostics.
//!
//! The validator / lint rules stamp a structured `data` payload on each
//! quickfixable diagnostic (`Diagnostic.QuickFixHint`). This module
//! dispatches on that payload — no message-text parsing — and uses
//! source-side helpers (`findLocationAttrRange`, `findVertexReturnTarget`)
//! to locate the precise insertion ranges. The cast-target whitelist
//! (`isSafeCastTarget`) is still here because it operates on type names,
//! not diagnostic messages.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Range = Handler.Range;
const LspDiagnostic = Handler.LspDiagnostic;
const LspTextEdit = Handler.LspTextEdit;
const LspCodeAction = Handler.LspCodeAction;
const WgslDiagnostic = wgslender.Diagnostic;

/// Parse a WGSL numeric type name into a `(shape, scalar)` pair, or null if the
/// name is not a recognized scalar/short-vector/long-vector form.
///
///   "f32"       → .{ .shape = "", .scalar = "f32" }
///   "vec3f"     → .{ .shape = "vec3", .scalar = "f32" }
///   "vec3<f32>" → .{ .shape = "vec3", .scalar = "f32" }
///
/// Matrices, atomics, pointers, arrays, abstract types, and user structs return null.
fn parseCastableType(name: []const u8) ?struct { shape: []const u8, scalar: []const u8 } {
    const scalars = [_][]const u8{ "f32", "i32", "u32", "f16", "bool" };
    for (scalars) |s| {
        if (std.mem.eql(u8, name, s)) return .{ .shape = "", .scalar = s };
    }
    const sizes = [_][]const u8{ "vec2", "vec3", "vec4" };
    for (sizes) |size| {
        if (!std.mem.startsWith(u8, name, size)) continue;
        const tail = name[size.len..];
        // Short form: vec3f / vec3i / vec3u / vec3h
        if (tail.len == 1) {
            const scalar: []const u8 = switch (tail[0]) {
                'f' => "f32",
                'i' => "i32",
                'u' => "u32",
                'h' => "f16",
                else => return null,
            };
            return .{ .shape = size, .scalar = scalar };
        }
        // Long form: vec3<f32>
        if (tail.len >= 3 and tail[0] == '<' and tail[tail.len - 1] == '>') {
            const inner = tail[1 .. tail.len - 1];
            for (scalars) |s| {
                if (std.mem.eql(u8, inner, s)) return .{ .shape = size, .scalar = s };
            }
            return null;
        }
        return null;
    }
    return null;
}

/// Whitelist of WGSL type names that a quickfix may safely wrap an expression with
/// as a same-shape conversion constructor (e.g. `f32(x)`, `vec3f(v)`).
/// Rejects user-defined structs, abstract types, matrices, and shape-changing
/// targets (e.g. vec3 → vec4) where a plain constructor is not a valid conversion.
/// Accepts both short (`vec3f`) and long (`vec3<f32>`) spellings — the validator
/// emits the long form for vectors.
pub fn isSafeCastTarget(actual: []const u8, expected: []const u8) bool {
    const a = parseCastableType(actual) orelse return false;
    const e = parseCastableType(expected) orelse return false;
    return std.mem.eql(u8, a.shape, e.shape);
}

/// Compute code actions for the given diagnostics.
/// Caller owns the returned slice.
///
/// Dispatches on `diag.data` (`Diagnostic.QuickFixHint`). Diagnostics with
/// `data == .none` produce no actions — the validator / lint rules
/// stamp `data` only at emit sites where a quickfix is meaningful.
pub fn computeCodeActions(
    handler: *Handler,
    diags: []const LspDiagnostic,
) ![]LspCodeAction {
    var actions: std.ArrayListUnmanaged(LspCodeAction) = .empty;

    for (diags) |diag| switch (diag.data) {
        .none => {},
        .did_you_mean => |suggestion| addDidYouMeanAction(handler, &actions, diag, suggestion),
        .duplicate_location => |loc_val| addDuplicateLocationAction(handler, &actions, diag, loc_val),
        .vertex_missing_builtin_position => addVertexMissingPositionActions(handler, &actions, diag),
        .type_mismatch => |tm| addCastAction(handler, &actions, diag, tm),
        .unused_symbol => |name| addUnusedSymbolActions(handler, &actions, diag, name),
        .feature_not_enabled => |feature| addFeatureNotEnabledAction(handler, &actions, diag, feature),
    };

    return actions.toOwnedSlice(handler.gpa) catch &.{};
}

fn addDidYouMeanAction(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
    suggestion: []const u8,
) void {
    const title = std.fmt.allocPrint(handler.gpa, "Replace with '{s}'", .{suggestion}) catch return;
    const new_text = handler.gpa.dupe(u8, suggestion) catch {
        handler.gpa.free(title);
        return;
    };
    const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(new_text);
        handler.gpa.free(title);
        return;
    };
    edit[0] = .{ .range = diag.range, .new_text = new_text };
    actions.append(handler.gpa, .{
        .title = title,
        .kind = "quickfix",
        .is_preferred = true,
        .diagnostic = diag,
        .edits = edit,
    }) catch {
        handler.gpa.free(edit);
        handler.gpa.free(new_text);
        handler.gpa.free(title);
    };
}

fn addDuplicateLocationAction(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
    loc_val: u32,
) void {
    const new_val = loc_val + 1;
    const title = std.fmt.allocPrint(handler.gpa, "Change to @location({d})", .{new_val}) catch return;
    const new_text = std.fmt.allocPrint(handler.gpa, "@location({d})", .{new_val}) catch {
        handler.gpa.free(title);
        return;
    };
    const attr_range = findLocationAttrRange(handler, diag.range) orelse {
        handler.gpa.free(new_text);
        handler.gpa.free(title);
        return;
    };
    const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(new_text);
        handler.gpa.free(title);
        return;
    };
    edit[0] = .{ .range = attr_range, .new_text = new_text };
    actions.append(handler.gpa, .{
        .title = title,
        .kind = "quickfix",
        .is_preferred = false,
        .diagnostic = diag,
        .edits = edit,
    }) catch {
        handler.gpa.free(edit);
        handler.gpa.free(new_text);
        handler.gpa.free(title);
    };
}

fn addVertexMissingPositionActions(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
) void {
    switch (findVertexReturnTarget(handler, diag.range)) {
        .plain => |range| {
            const title = handler.gpa.dupe(u8, "Add @builtin(position) to return type") catch return;
            const new_text = handler.gpa.dupe(u8, "@builtin(position) ") catch {
                handler.gpa.free(title);
                return;
            };
            const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
                handler.gpa.free(new_text);
                handler.gpa.free(title);
                return;
            };
            edit[0] = .{ .range = range, .new_text = new_text };
            actions.append(handler.gpa, .{
                .title = title,
                .kind = "quickfix",
                .is_preferred = true,
                .diagnostic = diag,
                .edits = edit,
            }) catch {
                handler.gpa.free(edit);
                handler.gpa.free(new_text);
                handler.gpa.free(title);
            };
        },
        .struct_body => |sb| {
            const title = std.fmt.allocPrint(handler.gpa, "Add @builtin(position) member to '{s}'", .{sb.name}) catch return;
            const new_text = handler.gpa.dupe(u8, "@builtin(position) position: vec4f, ") catch {
                handler.gpa.free(title);
                return;
            };
            const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
                handler.gpa.free(new_text);
                handler.gpa.free(title);
                return;
            };
            edit[0] = .{ .range = sb.insert_at, .new_text = new_text };
            actions.append(handler.gpa, .{
                .title = title,
                .kind = "quickfix",
                .is_preferred = true,
                .diagnostic = diag,
                .edits = edit,
            }) catch {
                handler.gpa.free(edit);
                handler.gpa.free(new_text);
                handler.gpa.free(title);
            };
        },
        .none => {},
    }
}

/// Wrap the offending expression with `{expected}(...)`. The validator
/// only stamps `type_mismatch` when both types are known, but we still
/// gate on `isSafeCastTarget` here because the cast quickfix only makes
/// sense for same-shape scalar/vector pairs.
fn addCastAction(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
    tm: WgslDiagnostic.QuickFixHint.TypeMismatch,
) void {
    if (!isSafeCastTarget(tm.actual, tm.expected)) return;
    const source = blk: {
        var it = handler.documents.iterator();
        while (it.next()) |entry| {
            break :blk entry.value_ptr.source;
        }
        break :blk null;
    } orelse return;
    const start_off = Handler.lspPositionToOffset(source, diag.range.start) orelse return;
    const end_off = Handler.lspPositionToOffset(source, diag.range.end) orelse return;
    if (end_off <= start_off) return;
    const orig = source[start_off..end_off];

    const title = std.fmt.allocPrint(handler.gpa, "Cast to '{s}'", .{tm.expected}) catch return;
    const new_text = std.fmt.allocPrint(handler.gpa, "{s}({s})", .{ tm.expected, orig }) catch {
        handler.gpa.free(title);
        return;
    };
    const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(new_text);
        handler.gpa.free(title);
        return;
    };
    edit[0] = .{ .range = diag.range, .new_text = new_text };
    actions.append(handler.gpa, .{
        .title = title,
        .kind = "quickfix",
        .is_preferred = false,
        .diagnostic = diag,
        .edits = edit,
    }) catch {
        handler.gpa.free(edit);
        handler.gpa.free(new_text);
        handler.gpa.free(title);
    };
}

fn addUnusedSymbolActions(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
    name: []const u8,
) void {
    // Primary: delete the whole declaration line.
    const title = std.fmt.allocPrint(handler.gpa, "Remove unused '{s}'", .{name}) catch return;
    const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(title);
        return;
    };
    edit[0] = .{
        .range = .{
            .start = .{ .line = diag.range.start.line, .character = 0 },
            .end = .{ .line = diag.range.start.line + 1, .character = 0 },
        },
        .new_text = handler.gpa.dupe(u8, "") catch "",
    };
    actions.append(handler.gpa, .{
        .title = title,
        .kind = "quickfix",
        .diagnostic = diag,
        .edits = edit,
    }) catch {
        handler.gpa.free(edit);
        handler.gpa.free(title);
        return;
    };

    // Secondary: rename to `_name` (silences the lint without removing
    // the declaration). Skip names that already start with `_` to avoid
    // double-underscore.
    if (name.len == 0 or name[0] == '_') return;
    const rename_title = std.fmt.allocPrint(handler.gpa, "Rename to '_{s}'", .{name}) catch return;
    const rename_new_text = std.fmt.allocPrint(handler.gpa, "_{s}", .{name}) catch {
        handler.gpa.free(rename_title);
        return;
    };
    const rename_edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(rename_new_text);
        handler.gpa.free(rename_title);
        return;
    };
    rename_edit[0] = .{ .range = diag.range, .new_text = rename_new_text };
    actions.append(handler.gpa, .{
        .title = rename_title,
        .kind = "quickfix",
        .is_preferred = false,
        .diagnostic = diag,
        .edits = rename_edit,
    }) catch {
        handler.gpa.free(rename_edit);
        handler.gpa.free(rename_new_text);
        handler.gpa.free(rename_title);
    };
}

fn addFeatureNotEnabledAction(
    handler: *Handler,
    actions: *std.ArrayListUnmanaged(LspCodeAction),
    diag: LspDiagnostic,
    feature: []const u8,
) void {
    const title = std.fmt.allocPrint(handler.gpa, "Add 'enable {s};'", .{feature}) catch return;
    const new_text = std.fmt.allocPrint(handler.gpa, "enable {s};\n", .{feature}) catch {
        handler.gpa.free(title);
        return;
    };
    const edit = handler.gpa.alloc(LspTextEdit, 1) catch {
        handler.gpa.free(new_text);
        handler.gpa.free(title);
        return;
    };
    edit[0] = .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
        .new_text = new_text,
    };
    actions.append(handler.gpa, .{
        .title = title,
        .kind = "quickfix",
        .is_preferred = true,
        .diagnostic = diag,
        .edits = edit,
    }) catch {
        handler.gpa.free(edit);
        handler.gpa.free(new_text);
        handler.gpa.free(title);
    };
}

/// Result of locating where to insert `@builtin(position)` to fix an E0600
/// vertex-missing-position diagnostic.
pub const VertexReturnTarget = union(enum) {
    /// Non-struct return type: insert `@builtin(position) ` at this range
    /// (empty range immediately before the return-type tokens).
    plain: Range,
    /// Struct return type: insert a new `@builtin(position) position: vec4f,`
    /// member at `insert_at` (empty range just before the struct's closing `}`).
    struct_body: struct {
        name: []const u8,
        insert_at: Range,
    },
    /// Source isn't shaped as expected (no `->`, struct body unbalanced, etc.).
    /// Surface this as "no action" rather than produce a wrong edit.
    none,
};

/// Search the document source around a vertex-entry-point diagnostic to find where
/// `@builtin(position)` should be inserted. See `VertexReturnTarget` for the two
/// cases: plain return type or struct return type.
fn findVertexReturnTarget(handler: *Handler, diag_range: Range) VertexReturnTarget {
    var it = handler.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        const name_start = Handler.lspPositionToOffset(source, diag_range.start) orelse continue;
        if (name_start >= source.len) continue;

        // Scan forward from the function name for `->`, bounded to avoid running
        // into the next top-level decl on malformed input.
        const window_end = @min(source.len, name_start + 512);
        const arrow_rel = std.mem.indexOf(u8, source[name_start..window_end], "->") orelse continue;
        var off = name_start + arrow_rel + 2;

        // Skip whitespace after `->`.
        while (off < source.len and (source[off] == ' ' or source[off] == '\t' or
            source[off] == '\n' or source[off] == '\r')) : (off += 1)
        {}
        if (off >= source.len) continue;

        // Read an identifier token. If what follows `->` starts with `@` (an
        // attribute like `@location(0) vec4f`), fall into the plain branch:
        // prepending `@builtin(position) ` to the attribute list is still a
        // reasonable best-effort fix.
        const id_start = off;
        while (off < source.len and isIdentChar(source[off])) : (off += 1) {}
        const id_end = off;
        if (id_end == id_start) {
            // Starts with `@` or something else — use the plain insertion point.
            return makePlainTarget(handler.gpa, source, id_start) orelse .none;
        }
        const type_name = source[id_start..id_end];

        // Scalars and vectors take the plain branch; otherwise look for a struct
        // declaration matching the identifier.
        if (parseCastableType(type_name) != null) {
            return makePlainTarget(handler.gpa, source, id_start) orelse .none;
        }

        if (findStructBodyInsertPoint(handler.gpa, source, type_name)) |insert_at| {
            return .{ .struct_body = .{ .name = type_name, .insert_at = insert_at } };
        }
        // Fall through: unrecognized type name, no matching struct — best effort
        // is to prepend `@builtin(position) ` before the identifier.
        return makePlainTarget(handler.gpa, source, id_start) orelse .none;
    }
    return .none;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn makePlainTarget(gpa: std.mem.Allocator, source: []const u8, offset: usize) ?VertexReturnTarget {
    var line_index = WgslDiagnostic.LineIndex.init(gpa, source) catch return null;
    defer line_index.deinit(gpa);
    const pos = line_index.byteOffsetToLineColumn(@intCast(offset));
    const range: Range = .{
        .start = .{ .line = pos.line, .character = pos.col },
        .end = .{ .line = pos.line, .character = pos.col },
    };
    return .{ .plain = range };
}

fn findStructBodyInsertPoint(gpa: std.mem.Allocator, source: []const u8, struct_name: []const u8) ?Range {
    // Scan source for `struct <name>` followed by `{`. Accept any whitespace or
    // attribute list between `struct` and the name (keep it simple: find each
    // occurrence of `struct` and check that the next identifier matches).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "struct")) |idx| {
        // Require a word boundary before (start-of-file or non-ident char).
        const ok_before = idx == 0 or !isIdentChar(source[idx - 1]);
        // And after: `struct` must be followed by whitespace (or EOF).
        const after = idx + "struct".len;
        const ok_after = after < source.len and !isIdentChar(source[after]);
        if (!ok_before or !ok_after) {
            i = idx + 1;
            continue;
        }
        var j = after;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t' or
            source[j] == '\n' or source[j] == '\r')) : (j += 1)
        {}
        const name_start = j;
        while (j < source.len and isIdentChar(source[j])) : (j += 1) {}
        const name_end = j;
        if (name_end == name_start or !std.mem.eql(u8, source[name_start..name_end], struct_name)) {
            i = idx + 1;
            continue;
        }
        // Find `{` after the name.
        while (j < source.len and source[j] != '{' and source[j] != ';') : (j += 1) {}
        if (j >= source.len or source[j] != '{') {
            i = idx + 1;
            continue;
        }
        const body_open = j;
        // Find the matching `}`. WGSL struct bodies don't contain other braces.
        const close_off = std.mem.indexOfScalarPos(u8, source, body_open + 1, '}') orelse return null;

        var line_index = WgslDiagnostic.LineIndex.init(gpa, source) catch return null;
        defer line_index.deinit(gpa);
        const pos = line_index.byteOffsetToLineColumn(@intCast(close_off));
        const range: Range = .{
            .start = .{ .line = pos.line, .character = pos.col },
            .end = .{ .line = pos.line, .character = pos.col },
        };
        return range;
    }
    return null;
}

/// Search the document source near a diagnostic range to find the actual
/// @location(N) attribute range, so the edit replaces the whole annotation.
fn findLocationAttrRange(handler: *Handler, diag_range: Range) ?Range {
    // We need the source to scan for @location(...) near the diagnostic.
    // Iterate all open documents to find one containing this range.
    // (Code actions are always for the current document, so we check all.)
    var it = handler.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        // Convert LSP 0-based line/col to byte offset in the source.
        if (Handler.lspPositionToOffset(source, diag_range.start)) |start_offset| {
            // Search backwards from the diagnostic start for @location(
            const search_start = if (start_offset > 30) start_offset - 30 else 0;
            const region = source[search_start..@min(source.len, start_offset + 50)];
            if (std.mem.indexOf(u8, region, "@location(")) |rel_idx| {
                const abs_start = search_start + rel_idx;
                // Find the closing )
                if (std.mem.indexOfPos(u8, source, abs_start, ")")) |close_paren| {
                    const abs_end = close_paren + 1; // include the )
                    // Convert back to LSP positions
                    var line_index = WgslDiagnostic.LineIndex.init(handler.gpa, source) catch return null;
                    // LineIndex is 0-based; LSP is also 0-based
                    const s = line_index.byteOffsetToLineColumn(@intCast(abs_start));
                    const e = line_index.byteOffsetToLineColumn(@intCast(abs_end));
                    line_index.deinit(handler.gpa);
                    return .{
                        .start = .{ .line = s.line, .character = s.col },
                        .end = .{ .line = e.line, .character = e.col },
                    };
                }
            }
        }
    }
    return null;
}

/// Frees all allocations within a code actions slice (titles, edits, the slice itself).
pub fn freeCodeActions(gpa: std.mem.Allocator, actions: []LspCodeAction) void {
    for (actions) |a| {
        gpa.free(a.title);
        for (a.edits) |edit| {
            gpa.free(edit.new_text);
        }
        gpa.free(a.edits);
    }
    gpa.free(actions);
}

// =========================================================================
// Tests
// =========================================================================

test "computeCodeActions: did-you-mean produces rename action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 8 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
        .data = .{ .did_you_mean = "position" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("quickfix", actions[0].kind);
    try std.testing.expect(actions[0].is_preferred);
    try std.testing.expectEqual(@as(usize, 1), actions[0].edits.len);
    try std.testing.expectEqualStrings("position", actions[0].edits[0].new_text);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 8), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: data=.none produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'zzzzz'",
        .code = "E0100",
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: non-fixable diagnostic produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "break statement must be inside loop",
        .code = "E0500",
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: multiple diagnostics produce multiple actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
            .data = .{ .did_you_mean = "position" },
        },
        .{
            .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 4 } },
            .severity = .@"error",
            .message = "unknown type 'vec3'; did you mean 'vec3f'?",
            .code = "E0200",
            .data = .{ .did_you_mean = "vec3f" },
        },
    };

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Replace with 'vec3f'", actions[1].title);
}

test "computeCodeActions: E0206 no_such_member with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 11 } },
        .severity = .@"error",
        .message = "struct 'Foo' has no member 'y'; did you mean 'x'?",
        .code = "E0206",
        .data = .{ .did_you_mean = "x" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'x'", actions[0].title);
    try std.testing.expectEqualStrings("x", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0403 invalid builtin with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 17 } },
        .severity = .@"error",
        .message = "unknown @builtin value 'positon'; did you mean 'position'?",
        .code = "E0403",
        .data = .{ .did_you_mean = "position" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
}

test "computeCodeActions: E0204 not_callable with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 18 } },
        .severity = .@"error",
        .message = "'sin_wrong' is not callable; did you mean 'sin'?",
        .code = "E0204",
        .data = .{ .did_you_mean = "sin" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'sin'", actions[0].title);
}

test "computeCodeActions: empty diagnostic array" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{};
    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: zero-width diagnostic range still produces action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
        .data = .{ .did_you_mean = "position" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: E0602 duplicate location increment" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
        .data = .{ .duplicate_location = 0 },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[0].title);
    try std.testing.expectEqualStrings("@location(1)", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0602 with no open document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // No documents → findLocationAttrRange returns null → no action.
    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
        .data = .{ .duplicate_location = 0 },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: E0602 multi-digit location" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(99) a: f32, @location(99) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 22 }, .end = .{ .line = 0, .character = 35 } },
        .severity = .@"error",
        .message = "duplicate input @location(99)",
        .code = "E0602",
        .data = .{ .duplicate_location = 99 },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(100)", actions[0].title);
    try std.testing.expectEqualStrings("@location(100)", actions[0].edits[0].new_text);
}

test "computeCodeActions: mixed diagnostics produce correct actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
            .data = .{ .did_you_mean = "position" },
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
            .severity = .@"error",
            .message = "duplicate input @location(0)",
            .code = "E0602",
            .data = .{ .duplicate_location = 0 },
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
            .severity = .@"error",
            .message = "break statement must be inside loop",
            .code = "E0500",
        },
    };

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[1].title);
}

test "computeCodeActions: W0001 unused symbol produces remove + rename" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 2, .character = 4 }, .end = .{ .line = 2, .character = 7 } },
        .severity = .warning,
        .message = "'foo' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "foo" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Remove unused 'foo'", actions[0].title);
    try std.testing.expectEqualStrings("Rename to '_foo'", actions[1].title);
    try std.testing.expectEqualStrings("_foo", actions[1].edits[0].new_text);
}

test "computeCodeActions: W0001 underscore-prefixed name skips rename" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
        .severity = .warning,
        .message = "'_foo' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "_foo" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Remove unused '_foo'", actions[0].title);
}

test "computeCodeActions: E0900 feature_not_enabled inserts enable directive" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 5, .character = 8 }, .end = .{ .line = 5, .character = 11 } },
        .severity = .@"error",
        .message = "'f16' requires 'enable f16;'",
        .code = "E0900",
        .data = .{ .feature_not_enabled = "f16" },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Add 'enable f16;'", actions[0].title);
    try std.testing.expectEqualStrings("enable f16;\n", actions[0].edits[0].new_text);
    try std.testing.expectEqual(@as(u32, 0), actions[0].edits[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), actions[0].edits[0].range.start.character);
}

test "computeCodeActions: E0200 type_mismatch wraps with cast" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "let x: i32 = y;\n", 1);

    const diags = [_]LspDiagnostic{.{
        // Range covers "y" (character 13..14).
        .range = .{ .start = .{ .line = 0, .character = 13 }, .end = .{ .line = 0, .character = 14 } },
        .severity = .@"error",
        .message = "cannot assign 'f32' to 'i32'",
        .code = "E0200",
        .data = .{ .type_mismatch = .{ .actual = "f32", .expected = "i32" } },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Cast to 'i32'", actions[0].title);
    try std.testing.expectEqualStrings("i32(y)", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0200 type_mismatch with non-castable types produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "let x: vec3f = y;\n", 1);

    // vec3 → vec4 is shape-changing, not a safe cast.
    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 15 }, .end = .{ .line = 0, .character = 16 } },
        .severity = .@"error",
        .message = "cannot assign 'vec4<f32>' to 'vec3<f32>'",
        .code = "E0200",
        .data = .{ .type_mismatch = .{ .actual = "vec4<f32>", .expected = "vec3<f32>" } },
    }};

    const actions = try computeCodeActions(&handler, &diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}
