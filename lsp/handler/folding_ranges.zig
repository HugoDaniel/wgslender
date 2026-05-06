//! Folding Ranges: identify multi-line declaration bodies (functions,
//! structs) so the editor can collapse them.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");

pub const FoldingRangeInfo = struct {
    start_line: u32,
    end_line: u32,
    kind: enum { region, comment },
};

pub fn computeFoldingRanges(handler: *Handler, uri: []const u8) ![]FoldingRangeInfo {
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var ranges: std.ArrayList(FoldingRangeInfo) = .empty;
    defer ranges.deinit(handler.gpa);

    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (f.body == null) continue;
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                const start_pos = Handler.offsetToLspPosition(source, sym.loc) orelse continue;
                // Find closing brace by scanning source
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = Handler.offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(handler.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            .@"struct" => |s| {
                if (!s.name.isValid()) continue;
                const sym = module.symbols.items[s.name.index()];
                const start_pos = Handler.offsetToLspPosition(source, sym.loc) orelse continue;
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = Handler.offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(handler.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            else => {},
        }
    }

    return try handler.gpa.dupe(FoldingRangeInfo, ranges.items);
}

/// Scan source from `start` to find the matching `}` for the next `{`.
/// Used by both folding ranges and selection ranges.
pub fn findClosingBrace(source: []const u8, start: u32) ?u32 {
    var depth: i32 = 0;
    var i: u32 = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '{') {
            depth += 1;
        } else if (source[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}
