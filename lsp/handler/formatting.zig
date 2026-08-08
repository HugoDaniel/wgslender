//! Formatting: run the wgslender printer pipeline with every content
//! transformation disabled to produce a canonically-formatted document.
//! Formatting must be content-preserving: no tree shaking (it would
//! delete not-yet-called helpers), no syntax minification (it would
//! respell literals like `1.0` as `1.`), no renaming.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const LspTextEdit = Handler.LspTextEdit;

pub fn computeFormatting(handler: *Handler, uri: []const u8) !?LspTextEdit {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;

    // Parse and print with non-minified settings
    const source_z = try handler.gpa.dupeZ(u8, source);
    defer handler.gpa.free(source_z);

    var options = wgslender.Minifier.defaultOptions();
    options.minify_whitespace = false;
    options.minify_identifiers = false;
    options.minify_syntax = false;
    options.tree_shaking = false;

    var result = try wgslender.minifyWithOptions(handler.gpa, source_z, options);
    defer result.deinit(handler.gpa);

    if (result.errors.len > 0) return null; // Can't format with parse errors

    // Compute the end position of the document
    const end_pos = Handler.offsetToLspPosition(source, @intCast(source.len)) orelse return null;

    return .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = end_pos,
        },
        .new_text = try handler.gpa.dupe(u8, result.code),
    };
}
