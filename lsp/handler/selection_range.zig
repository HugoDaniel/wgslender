//! Selection Range: return the chain of progressively-larger selections
//! around a cursor (whole-name → enclosing decl → file).

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const FoldingRanges = @import("folding_ranges.zig");
const Position = Handler.Position;
const Range = Handler.Range;

pub const SelectionRangeInfo = struct {
    range: Range,
    parent: ?*const SelectionRangeInfo,
};

pub fn computeSelectionRange(handler: *Handler, uri: []const u8, position: Position) !?*SelectionRangeInfo {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;

    // One line index for the request. The whole-file range alone made this
    // O(source) — `offsetToLspPosition(source, source.len)` walks every
    // byte; the mapper answers it from the last line-start entry.
    var pm = try Handler.PositionMapper.init(handler.gpa, source);
    defer pm.deinit(handler.gpa);

    const offset: u32 = @intCast(pm.offsetOf(position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    // Build chain from innermost to outermost:
    // 1. Whole file (always the outermost)
    const file_range = pm.range(0, @intCast(source.len)) orelse return null;
    const file_node = try handler.gpa.create(SelectionRangeInfo);
    file_node.* = .{ .range = file_range, .parent = null };

    // 2. Find which declaration contains the offset
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (f.body == null) continue;
                // Check if offset is within this function's range
                const end_offset = FoldingRanges.findClosingBrace(source, sym.loc) orelse continue;
                if (offset < sym.loc or offset > end_offset) continue;

                // Function declaration range
                const fn_range = pm.range(sym.loc, end_offset + 1) orelse continue;
                const fn_node = try handler.gpa.create(SelectionRangeInfo);
                fn_node.* = .{ .range = fn_range, .parent = file_node };

                // Name range
                const name_range = pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
                if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
                    const name_node = try handler.gpa.create(SelectionRangeInfo);
                    name_node.* = .{ .range = name_range, .parent = fn_node };
                    return name_node;
                }

                return fn_node;
            },
            .@"struct" => |s| {
                if (!s.name.isValid()) continue;
                const sym = module.symbols.items[s.name.index()];
                const end_offset = FoldingRanges.findClosingBrace(source, sym.loc) orelse continue;
                if (offset < sym.loc or offset > end_offset) continue;

                const struct_range = pm.range(sym.loc, end_offset + 1) orelse continue;
                const struct_node = try handler.gpa.create(SelectionRangeInfo);
                struct_node.* = .{ .range = struct_range, .parent = file_node };
                return struct_node;
            },
            else => {
                const name_ref = decl.nameRef();
                if (!name_ref.isValid()) continue;
                const sym = module.symbols.items[name_ref.index()];
                if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
                    const range = pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
                    const node = try handler.gpa.create(SelectionRangeInfo);
                    node.* = .{ .range = range, .parent = file_node };
                    return node;
                }
            },
        }
    }

    return file_node;
}
