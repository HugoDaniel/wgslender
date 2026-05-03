//! Unused-Symbol Warnings: append warning-severity diagnostics for
//! symbols, dead code, and bindings that are declared but unused.
//! Called by the diagnostics pipeline after analysis.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const LspDiagnostic = Handler.LspDiagnostic;

/// Append warnings for unused symbols to a diagnostics list.
/// Called after analysis to supplement validation diagnostics.
pub fn appendUnusedWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items, 0..) |sym, idx| {
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_api_facing) continue;
        if (sym.flags.is_external_binding) continue;

        // Only warn for user-declared symbols
        switch (sym.kind) {
            .function, .@"const", .let, .@"var", .override => {},
            .parameter => {
                // Skip parameters of entry point functions
                // We can't easily detect this from the symbol alone,
                // so skip all parameters for now (they may be required by signature)
                continue;
            },
            else => continue,
        }

        _ = idx;
        const range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is declared but never used", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .warning,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0001",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}

/// Append hint-level diagnostics for symbols that are used internally
/// but not reachable from any entry point. Only emits when entry points exist.
pub fn appendDeadCodeWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    // Check if any entry points exist. If none, DCE conservatively marks
    // everything live (library mode), so there's nothing to warn about.
    var has_entry_points = false;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_entry_point) {
            has_entry_points = true;
            break;
        }
    }
    if (!has_entry_points) return;

    for (module.symbols.items) |sym| {
        // Only flag symbols that are used (use_count > 0) but not live
        if (sym.flags.is_live) continue;
        if (sym.use_count == 0) continue; // Already caught by appendUnusedWarnings
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_external_binding) continue;

        switch (sym.kind) {
            .function, .@"struct", .@"const", .let, .@"var", .override => {},
            else => continue,
        }

        const range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is not reachable from any entry point", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .hint,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0002",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}

/// Append warnings for binding variables (@group/@binding) that are declared but never used.
/// These consume bind group layout slots even when unused.
pub fn appendUnusedBindingWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayListUnmanaged(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items) |sym| {
        if (!sym.flags.is_external_binding) continue;
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;

        const range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "binding variable '{s}' is declared but never used — it will consume a bind group layout slot", .{sym.original_name}) catch continue;
        diags.append(gpa, .{
            .range = range,
            .severity = .warning,
            .message = gpa.dupe(u8, msg) catch continue,
            .code = "W0003",
            .tags = &.{.unnecessary},
        }) catch continue;
    }
}
