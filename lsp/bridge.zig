//! Bridge: `Handler.LspDiagnostic` → `lsp.types.Diagnostic`.
//!
//! Extracted from `main.zig` so the JSON-payload tests can call it
//! without spinning up a full native server. `Handler.zig` itself
//! stays lsp-kit-free (that constraint lets the wasm LSP build compile).

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");

/// Owns the bridged `lsp.types.Diagnostic` slice plus every sub-slice
/// (relatedInformation, tags) allocated while translating from
/// `Handler.LspDiagnostic`. Uses an internal arena so callers free the
/// entire payload with a single `deinit()`.
pub const BridgedDiagnostics = struct {
    diagnostics: []lsp.types.Diagnostic,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BridgedDiagnostics) void {
        self.arena.deinit();
    }
};

/// Translate Handler's transport-agnostic diagnostics into the lsp-kit
/// JSON-shaped representation.
///
/// `uri` is attached as the `location.uri` of every relatedInformation
/// entry (WGSL diagnostics are always intra-document). String fields
/// (`message`, `code`, `spec_url`, related messages) are borrowed from
/// `handler_diags` — the caller must keep that slice alive until the
/// serialized JSON is written.
///
/// Fails only if the top-level diagnostics slice can't be allocated.
/// Individual relatedInformation / tags allocations degrade to `null`
/// on OOM so the rest of the diagnostic still reaches the client.
pub fn toLspKitDiagnostics(
    gpa: std.mem.Allocator,
    handler_diags: []const Handler.LspDiagnostic,
    uri: []const u8,
) !BridgedDiagnostics {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const diags = try aa.alloc(lsp.types.Diagnostic, handler_diags.len);

    for (handler_diags, 0..) |d, i| {
        var related_info: ?[]const lsp.types.Diagnostic.RelatedInformation = null;
        if (d.related.len > 0) {
            if (aa.alloc(lsp.types.Diagnostic.RelatedInformation, d.related.len)) |rel| {
                for (d.related, 0..) |rel_item, ri| {
                    rel[ri] = .{
                        .location = .{
                            .uri = uri,
                            .range = .{
                                .start = .{ .line = rel_item.range.start.line, .character = rel_item.range.start.character },
                                .end = .{ .line = rel_item.range.end.line, .character = rel_item.range.end.character },
                            },
                        },
                        .message = rel_item.message,
                    };
                }
                related_info = rel;
            } else |_| {}
        }

        var tags_slice: ?[]const lsp.types.Diagnostic.Tag = null;
        if (d.tags.len > 0) {
            if (aa.alloc(lsp.types.Diagnostic.Tag, d.tags.len)) |t| {
                for (d.tags, 0..) |tag, ti| t[ti] = switch (tag) {
                    .unnecessary => .Unnecessary,
                    .deprecated => .Deprecated,
                };
                tags_slice = t;
            } else |_| {}
        }

        diags[i] = .{
            .range = .{
                .start = .{ .line = d.range.start.line, .character = d.range.start.character },
                .end = .{ .line = d.range.end.line, .character = d.range.end.character },
            },
            .severity = switch (d.severity) {
                .@"error" => .Error,
                .warning => .Warning,
                .information => .Information,
                .hint => .Hint,
            },
            .code = if (d.code.len > 0) .{ .string = d.code } else null,
            .codeDescription = if (d.spec_url.len > 0) .{ .href = d.spec_url } else null,
            .source = "wgslender",
            .message = d.message,
            .tags = tags_slice,
            .relatedInformation = related_info,
        };
    }

    return .{
        .diagnostics = diags,
        .arena = arena,
    };
}
