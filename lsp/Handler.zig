//! WGSL Language Server — shared handler logic.
//!
//! Transport-agnostic core used by both the native (stdio) and WASM
//! entry points. Manages open documents, runs wgslender validation,
//! and converts diagnostics to a simple LSP-compatible format.
//!
//! This module has NO dependency on lsp-kit so it compiles for WASM.

const std = @import("std");
const wgslender = @import("wgslender");

const WgslDiagnostic = wgslender.Diagnostic;

const Handler = @This();

allocator: std.mem.Allocator,
documents: std.StringHashMapUnmanaged(Document),

pub const Document = struct {
    source: []u8,
    version: i32,
};

// =========================================================================
// LSP-compatible diagnostic (no lsp-kit dependency)
// =========================================================================

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

pub const DiagnosticSeverity = enum(u32) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const LspRelatedInfo = struct {
    range: Range,
    message: []const u8,
};

pub const LspDiagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    code: []const u8 = "",
    spec_url: []const u8 = "",
    related: []const LspRelatedInfo = &.{},
};

pub const LspTextEdit = struct {
    range: Range,
    new_text: []const u8,
};

pub const LspCodeAction = struct {
    title: []const u8,
    kind: []const u8, // "quickfix"
    is_preferred: bool = false,
    diagnostic: LspDiagnostic,
    edits: []const LspTextEdit,
};

/// Server capabilities as a JSON string (shared by native and WASM).
pub const capabilities_json =
    \\{"textDocumentSync":{"openClose":true,"change":1},"positionEncoding":"utf-16","codeActionProvider":{"codeActionKinds":["quickfix"]}}
;

pub fn init(allocator: std.mem.Allocator) Handler {
    return .{
        .allocator = allocator,
        .documents = .empty,
    };
}

pub fn deinit(self: *Handler) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.source);
    }
    self.documents.deinit(self.allocator);
}

// =========================================================================
// Document management
// =========================================================================

pub fn openDocument(self: *Handler, uri: []const u8, text: []const u8, version: i32) !void {
    const new_source = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(new_source);

    const gop = try self.documents.getOrPut(self.allocator, uri);
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.source);
    } else {
        gop.key_ptr.* = try self.allocator.dupe(u8, uri);
    }
    gop.value_ptr.* = .{ .source = new_source, .version = version };
}

pub fn changeDocument(self: *Handler, uri: []const u8, text: []const u8) !void {
    const doc = self.documents.getPtr(uri) orelse return;
    const new_source = try self.allocator.dupe(u8, text);
    self.allocator.free(doc.source);
    doc.source = new_source;
}

pub fn closeDocument(self: *Handler, uri: []const u8) void {
    const entry = self.documents.fetchRemove(uri) orelse return;
    self.allocator.free(entry.key);
    self.allocator.free(entry.value.source);
}

pub fn getDocumentSource(self: *const Handler, uri: []const u8) ?[]const u8 {
    const doc = self.documents.get(uri) orelse return null;
    return doc.source;
}

// =========================================================================
// Diagnostics
// =========================================================================

/// Run wgslender validation and return LSP diagnostics.
/// Caller owns the returned slice — free with the same allocator.
pub fn validateDocument(self: *Handler, source: []const u8) ![]LspDiagnostic {
    const source_z = try self.allocator.dupeZ(u8, source);
    defer self.allocator.free(source_z);

    var result = try wgslender.validateWithOptions(self.allocator, source_z, .{});
    defer result.deinit(self.allocator);

    const entries = result.diagnostics.diagnostics.items;
    const diags = try self.allocator.alloc(LspDiagnostic, entries.len);

    for (entries, 0..) |entry, i| {
        diags[i] = convertDiagnostic(self.allocator, &entry);
    }

    return diags;
}

const wgsl_spec_base = "https://www.w3.org/TR/WGSL/#";

fn convertDiagnostic(allocator: std.mem.Allocator, entry: *const WgslDiagnostic.Entry) LspDiagnostic {
    var related: []const LspRelatedInfo = &.{};
    if (entry.related.len > 0) {
        if (allocator.alloc(LspRelatedInfo, entry.related.len)) |rel| {
            for (entry.related, 0..) |r, ri| {
                rel[ri] = .{
                    .range = .{
                        .start = .{
                            .line = if (r.range.start.line > 0) r.range.start.line - 1 else 0,
                            .character = if (r.range.start.column > 0) r.range.start.column - 1 else 0,
                        },
                        .end = .{
                            .line = if (r.range.end.line > 0) r.range.end.line - 1 else 0,
                            .character = if (r.range.end.column > 0) r.range.end.column - 1 else 0,
                        },
                    },
                    .message = allocator.dupe(u8, r.message) catch r.message,
                };
            }
            related = rel;
        } else |_| {}
    }
    return .{
        .range = .{
            .start = .{
                .line = if (entry.range.start.line > 0) entry.range.start.line - 1 else 0,
                .character = if (entry.range.start.column > 0) entry.range.start.column - 1 else 0,
            },
            .end = .{
                .line = if (entry.range.end.line > 0) entry.range.end.line - 1 else 0,
                .character = if (entry.range.end.column > 0) entry.range.end.column - 1 else 0,
            },
        },
        .severity = switch (entry.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .note => .information,
            else => .information,
        },
        .message = allocator.dupe(u8, entry.message) catch entry.message,
        .code = entry.code,
        .spec_url = if (entry.code.len > 0 and entry.spec_ref.len > 0) blk: {
            const url = allocator.alloc(u8, wgsl_spec_base.len + entry.spec_ref.len) catch break :blk "";
            @memcpy(url[0..wgsl_spec_base.len], wgsl_spec_base);
            @memcpy(url[wgsl_spec_base.len..], entry.spec_ref);
            break :blk url;
        } else "",
        .related = related,
    };
}

// =========================================================================
// Code Actions
// =========================================================================

/// Extract the suggestion from a "did you mean 'X'?" diagnostic message.
/// Returns the suggested name, or null if the message doesn't contain one.
pub fn extractDidYouMean(message: []const u8) ?[]const u8 {
    const needle = "; did you mean '";
    const idx = std.mem.indexOf(u8, message, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, message, start, "'") orelse return null;
    if (start >= end) return null;
    return message[start..end];
}

/// Extract the location number from a "duplicate input/output @location(N)" message.
/// Returns the numeric value N, or null if the message doesn't match.
pub fn extractDuplicateLocation(message: []const u8) ?i64 {
    // Look for "duplicate input @location(" or "duplicate output @location("
    const patterns = [_][]const u8{ "duplicate input @location(", "duplicate output @location(" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern)) |idx| {
            const start = idx + pattern.len;
            const end = std.mem.indexOfPos(u8, message, start, ")") orelse continue;
            if (start >= end) continue;
            return std.fmt.parseInt(i64, message[start..end], 10) catch continue;
        }
    }
    return null;
}

/// Compute code actions for the given diagnostics.
/// Caller owns the returned slice.
pub fn computeCodeActions(
    self: *Handler,
    diags: []const LspDiagnostic,
) ![]LspCodeAction {
    var actions: std.ArrayListUnmanaged(LspCodeAction) = .empty;

    for (diags) |diag| {
        // "Did you mean?" rename fix
        if (isDidYouMeanCode(diag.code)) {
            if (extractDidYouMean(diag.message)) |suggestion| {
                const title = std.fmt.allocPrint(self.allocator, "Replace with '{s}'", .{suggestion}) catch continue;
                const new_text = self.allocator.dupe(u8, suggestion) catch {
                    self.allocator.free(title);
                    continue;
                };
                const edit = self.allocator.alloc(LspTextEdit, 1) catch {
                    self.allocator.free(new_text);
                    self.allocator.free(title);
                    continue;
                };
                edit[0] = .{ .range = diag.range, .new_text = new_text };
                actions.append(self.allocator, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = true,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.allocator.free(edit);
                    self.allocator.free(new_text);
                    self.allocator.free(title);
                };
            }
        }

        // Duplicate @location(N) → increment to N+1
        if (std.mem.eql(u8, diag.code, "E0602")) {
            if (extractDuplicateLocation(diag.message)) |loc_val| {
                const new_val = loc_val + 1;
                const title = std.fmt.allocPrint(self.allocator, "Change to @location({d})", .{new_val}) catch continue;
                const new_text = std.fmt.allocPrint(self.allocator, "@location({d})", .{new_val}) catch {
                    self.allocator.free(title);
                    continue;
                };
                // Find @location(...) within the source at the diagnostic range
                const attr_range = self.findLocationAttrRange(diag.range) orelse {
                    self.allocator.free(new_text);
                    self.allocator.free(title);
                    continue;
                };
                const edit = self.allocator.alloc(LspTextEdit, 1) catch {
                    self.allocator.free(new_text);
                    self.allocator.free(title);
                    continue;
                };
                edit[0] = .{ .range = attr_range, .new_text = new_text };
                actions.append(self.allocator, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = false,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.allocator.free(edit);
                    self.allocator.free(new_text);
                    self.allocator.free(title);
                };
            }
        }
    }

    return actions.toOwnedSlice(self.allocator) catch &.{};
}

fn isDidYouMeanCode(code: []const u8) bool {
    // E0100 = undefined_symbol, E0200 = type_mismatch (unknown type),
    // E0204 = not_callable, E0206 = no_such_member, E0403 = invalid_builtin
    return std.mem.eql(u8, code, "E0100") or
        std.mem.eql(u8, code, "E0200") or
        std.mem.eql(u8, code, "E0204") or
        std.mem.eql(u8, code, "E0206") or
        std.mem.eql(u8, code, "E0403");
}

/// Search the document source near a diagnostic range to find the actual
/// @location(N) attribute range, so the edit replaces the whole annotation.
fn findLocationAttrRange(self: *Handler, diag_range: Range) ?Range {
    // We need the source to scan for @location(...) near the diagnostic.
    // Iterate all open documents to find one containing this range.
    // (Code actions are always for the current document, so we check all.)
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        // Convert LSP 0-based line/col to byte offset in the source.
        if (lspPositionToOffset(source, diag_range.start)) |start_offset| {
            // Search backwards from the diagnostic start for @location(
            const search_start = if (start_offset > 30) start_offset - 30 else 0;
            const region = source[search_start..@min(source.len, start_offset + 50)];
            if (std.mem.indexOf(u8, region, "@location(")) |rel_idx| {
                const abs_start = search_start + rel_idx;
                // Find the closing )
                if (std.mem.indexOfPos(u8, source, abs_start, ")")) |close_paren| {
                    const abs_end = close_paren + 1; // include the )
                    // Convert back to LSP positions
                    var line_index = WgslDiagnostic.LineIndex.init(self.allocator, source);
                    // LineIndex is 0-based; LSP is also 0-based
                    const s = line_index.byteOffsetToLineColumn(@intCast(abs_start));
                    const e = line_index.byteOffsetToLineColumn(@intCast(abs_end));
                    line_index.deinit(self.allocator);
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

/// Convert an LSP 0-based line:character position to a byte offset in source.
/// Handles LF, CR, and CRLF line endings.
pub fn lspPositionToOffset(source: []const u8, pos: Position) ?usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < source.len) {
        if (source[i] == '\r') {
            line += 1;
            // Skip LF in CRLF pair
            if (i + 1 < source.len and source[i + 1] == '\n') {
                i += 1;
            }
        } else if (source[i] == '\n') {
            line += 1;
        }
        i += 1;
    }
    if (line != pos.line) return null;
    const offset = i + pos.character;
    if (offset > source.len) return null;
    return offset;
}

// =========================================================================
// Tests
// =========================================================================

test "convertDiagnostic preserves code" {
    const entry = WgslDiagnostic.Entry{ .code = "E0200" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqualStrings("E0200", result.code);
}

test "convertDiagnostic builds spec_url from spec_ref" {
    const entry = WgslDiagnostic.Entry{ .code = "E0700", .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    defer std.testing.allocator.free(result.spec_url);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", result.spec_url);
}

test "convertDiagnostic omits code and spec_url when empty" {
    const entry = WgslDiagnostic.Entry{};
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.code.len);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

test "convertDiagnostic omits spec_url when code empty" {
    const entry = WgslDiagnostic.Entry{ .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []LspDiagnostic) void {
    for (diags) |d| {
        if (d.related.len > 0) {
            for (d.related) |r| {
                if (r.message.len > 0) allocator.free(r.message);
            }
            allocator.free(d.related);
        }
        if (d.message.len > 0) allocator.free(d.message);
        if (d.spec_url.len > 0) allocator.free(d.spec_url);
    }
    allocator.free(diags);
}

pub fn freeCodeActions(allocator: std.mem.Allocator, actions: []LspCodeAction) void {
    for (actions) |a| {
        allocator.free(a.title);
        for (a.edits) |edit| {
            allocator.free(edit.new_text);
        }
        allocator.free(a.edits);
    }
    allocator.free(actions);
}

test "code round-trips through validateDocument" {
    // A type mismatch triggers a diagnostic with code "E0200".
    const source =
        \\const x: i32 = 1.5;
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    // Find a diagnostic with a code
    for (diags) |d| {
        if (d.code.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, d.code, "E"));
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with a code, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

test "spec_url round-trips through validateDocument" {
    // workgroupBarrier inside a branch on a non-uniform builtin triggers
    // a uniformity error with code (E0701) and spec_ref ("uniformity").
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
        \\  if (global_invocation_id.x > 0) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    for (diags) |d| {
        if (d.spec_url.len > 0) {
            try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", d.spec_url);
            try std.testing.expect(d.code.len > 0);
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with spec_url, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// Code Action Tests
// =========================================================================

test "extractDidYouMean: undefined identifier" {
    const result = extractDidYouMean("use of undeclared identifier 'pos'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: unknown type" {
    const result = extractDidYouMean("unknown type 'vec3'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: no such member" {
    const result = extractDidYouMean("struct 'Foo' has no member 'y'; did you mean 'x'?");
    try std.testing.expectEqualStrings("x", result.?);
}

test "extractDidYouMean: not callable" {
    const result = extractDidYouMean("'foo' is not a function or type constructor; did you mean 'foo2'?");
    try std.testing.expectEqualStrings("foo2", result.?);
}

test "extractDidYouMean: invalid builtin" {
    const result = extractDidYouMean("unknown @builtin value 'positon'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: no suggestion" {
    try std.testing.expect(extractDidYouMean("type mismatch: expected 'f32'") == null);
}

test "extractDidYouMean: empty message" {
    try std.testing.expect(extractDidYouMean("") == null);
}

test "extractDuplicateLocation: input" {
    try std.testing.expectEqual(@as(i64, 0), extractDuplicateLocation("duplicate input @location(0)").?);
}

test "extractDuplicateLocation: output" {
    try std.testing.expectEqual(@as(i64, 3), extractDuplicateLocation("duplicate output @location(3)").?);
}

test "extractDuplicateLocation: no match" {
    try std.testing.expect(extractDuplicateLocation("some other error") == null);
}

test "extractDuplicateLocation: empty" {
    try std.testing.expect(extractDuplicateLocation("") == null);
}

test "computeCodeActions: did-you-mean produces rename action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 8 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("quickfix", actions[0].kind);
    try std.testing.expect(actions[0].is_preferred);
    try std.testing.expectEqual(@as(usize, 1), actions[0].edits.len);
    try std.testing.expectEqualStrings("position", actions[0].edits[0].new_text);
    // Edit range matches diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 8), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: no suggestion means no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'zzzzz'",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: non-matching code produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "break statement must be inside loop",
        .code = "E0500",
    }};

    const actions = try handler.computeCodeActions(&diags);
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
        },
        .{
            .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 4 } },
            .severity = .@"error",
            .message = "unknown type 'vec3'; did you mean 'vec3f'?",
            .code = "E0200",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
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
    }};

    const actions = try handler.computeCodeActions(&diags);
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
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
}

test "lspPositionToOffset: basic" {
    const source = "line1\nline2\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 6 (after "line1\n")
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 2, char 2 → offset 14
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 2 }).?);
}

test "lspPositionToOffset: past end" {
    const source = "ab";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 5, .character = 0 }) == null);
}

// =========================================================================
// Additional Edge Case Tests
// =========================================================================

test "lspPositionToOffset: CRLF line endings" {
    const source = "line1\r\nline2\r\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 7 (after "line1\r\n")
    try std.testing.expectEqual(@as(usize, 7), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 1, char 2 → offset 9
    try std.testing.expectEqual(@as(usize, 9), lspPositionToOffset(source, .{ .line = 1, .character = 2 }).?);
    // Line 2, char 0 → offset 14 (after "line1\r\nline2\r\n")
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: CR-only line endings" {
    const source = "line1\rline2\rline3";
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    try std.testing.expectEqual(@as(usize, 12), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: empty source" {
    try std.testing.expectEqual(@as(usize, 0), lspPositionToOffset("", .{ .line = 0, .character = 0 }).?);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 0, .character = 1 }) == null);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 1, .character = 0 }) == null);
}

test "lspPositionToOffset: position at exact end" {
    const source = "abc";
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // One past end returns null
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 4 }) == null);
}

test "lspPositionToOffset: character beyond line length" {
    const source = "short\nab";
    // character 100 on a 5-char line
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 100 }) == null);
}

test "extractDidYouMean: suggestion with underscores" {
    const result = extractDidYouMean("use of undeclared identifier 'global_id'; did you mean 'global_invocation_id'?");
    try std.testing.expectEqualStrings("global_invocation_id", result.?);
}

test "extractDidYouMean: suggestion with numbers" {
    const result = extractDidYouMean("unknown type 'vec3f32'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: single-character suggestion" {
    const result = extractDidYouMean("struct 'S' has no member 'ab'; did you mean 'a'?");
    try std.testing.expectEqualStrings("a", result.?);
}

test "extractDidYouMean: message with quotes but no suggestion" {
    // Has single quotes but not the "did you mean" pattern
    try std.testing.expect(extractDidYouMean("cannot initialize 'x' with type 'f32'") == null);
}

test "extractDuplicateLocation: multi-digit numbers" {
    try std.testing.expectEqual(@as(i64, 10), extractDuplicateLocation("duplicate input @location(10)").?);
    try std.testing.expectEqual(@as(i64, 99), extractDuplicateLocation("duplicate output @location(99)").?);
    try std.testing.expectEqual(@as(i64, 255), extractDuplicateLocation("duplicate input @location(255)").?);
}

test "extractDuplicateLocation: non-numeric content" {
    // @location with non-numeric value should return null
    try std.testing.expect(extractDuplicateLocation("duplicate input @location(abc)") == null);
}

test "computeCodeActions: E0204 not_callable with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
        .severity = .@"error",
        .message = "'foo' is not a function or type constructor; did you mean 'f32'?",
        .code = "E0204",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'f32'", actions[0].title);
    try std.testing.expectEqualStrings("f32", actions[0].edits[0].new_text);
}

test "computeCodeActions: empty diagnostic array" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{};
    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty code" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "some error; did you mean 'x'?",
        .code = "",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty code should not match any handler
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty message" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty message means no suggestion extractable
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: zero-width diagnostic range" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'x'; did you mean 'y'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Still produces action even with zero-width range (insertion)
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("y", actions[0].edits[0].new_text);
    // Edit range matches the zero-width diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: E0602 duplicate location increment" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // Register a source document so findLocationAttrRange can scan it
    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[0].title);
    try std.testing.expectEqualStrings("@location(1)", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0602 with no open document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // No document opened — findLocationAttrRange should return null
    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 10 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // No action because no document to scan
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: E0602 multi-digit location" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(10) a: f32, @location(10) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 22 }, .end = .{ .line = 0, .character = 36 } },
        .severity = .@"error",
        .message = "duplicate input @location(10)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(11)", actions[0].title);
    try std.testing.expectEqualStrings("@location(11)", actions[0].edits[0].new_text);
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
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
            .severity = .@"error",
            .message = "duplicate input @location(0)",
            .code = "E0602",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
            .severity = .@"error",
            .message = "break statement must be inside loop",
            .code = "E0500",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // E0100 produces rename, E0602 produces location fix, E0500 produces nothing
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[1].title);
}

test "isDidYouMeanCode: all supported codes" {
    try std.testing.expect(isDidYouMeanCode("E0100"));
    try std.testing.expect(isDidYouMeanCode("E0200"));
    try std.testing.expect(isDidYouMeanCode("E0204"));
    try std.testing.expect(isDidYouMeanCode("E0206"));
    try std.testing.expect(isDidYouMeanCode("E0403"));
}

test "isDidYouMeanCode: non-matching codes" {
    try std.testing.expect(!isDidYouMeanCode("E0500"));
    try std.testing.expect(!isDidYouMeanCode("E0602"));
    try std.testing.expect(!isDidYouMeanCode(""));
    try std.testing.expect(!isDidYouMeanCode("E0101"));
}
