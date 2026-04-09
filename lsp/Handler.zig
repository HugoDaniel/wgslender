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
    related: []const LspRelatedInfo = &.{},
};

/// Server capabilities as a JSON string (shared by native and WASM).
pub const capabilities_json =
    \\{"textDocumentSync":{"openClose":true,"change":1},"positionEncoding":"utf-16"}
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

fn convertDiagnostic(allocator: std.mem.Allocator, entry: *const WgslDiagnostic.Entry) LspDiagnostic {
    var related: []const LspRelatedInfo = &.{};
    if (entry.related.len > 0) {
        const rel = allocator.alloc(LspRelatedInfo, entry.related.len) catch &.{};
        if (rel.len > 0) {
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
                    .message = r.message,
                };
            }
            related = rel;
        }
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
        .message = entry.message,
        .related = related,
    };
}
