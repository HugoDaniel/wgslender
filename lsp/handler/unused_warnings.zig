//! Unused-Symbol Warnings: append warning-severity diagnostics for
//! symbols, dead code, and bindings that are declared but unused.
//! Called by the diagnostics pipeline after analysis.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const LspDiagnostic = Handler.LspDiagnostic;

/// Append warnings for unused symbols to a diagnostics list.
/// Called after analysis to supplement validation diagnostics.
/// The unused predicate lives on `AnalysisResult.isUnusedReportable` so
/// the `no-unused-vars` lint rule consults the exact same filter.
pub fn appendUnusedWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayList(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items, 0..) |sym, i| {
        if (!analysis.isUnusedReportable(@intCast(i))) continue;
        const range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is declared but never used", .{sym.original_name}) catch continue;
        const owned_msg = gpa.dupe(u8, msg) catch continue;
        const owned_name = gpa.dupe(u8, sym.original_name) catch {
            gpa.free(owned_msg);
            continue;
        };
        diags.append(gpa, .{
            .range = range,
            .severity = .warning,
            .message = owned_msg,
            .code = "W0001",
            .tags = &.{.unnecessary},
            .data = .{ .unused_symbol = owned_name },
        }) catch {
            gpa.free(owned_name);
            gpa.free(owned_msg);
            continue;
        };
    }
}

/// Append hint-level diagnostics for symbols that are used internally
/// but not reachable from any entry point. Only emits when entry points exist.
pub fn appendDeadCodeWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayList(LspDiagnostic),
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

    for (module.symbols.items, 0..) |sym, i| {
        // Only flag symbols that are used (use_count > 0) but not live
        if (analysis.liveness) |liv| {
            if (liv.isLive(@intCast(i))) continue;
        } else continue; // No liveness info available — can't make a safe call.
        const uc = if (i < analysis.use_counts.counts.len) analysis.use_counts.counts[i] else 0;
        if (uc == 0) continue; // Already caught by appendUnusedWarnings
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
/// These consume bind group layout slots even when unused. The predicate
/// lives on `AnalysisResult.isUnusedBindingReportable` so the
/// `no-unused-binding` lint rule consults the exact same filter.
pub fn appendUnusedBindingWarnings(
    gpa: std.mem.Allocator,
    analysis: *const wgslender.Validator.AnalysisResult,
    diags: *std.ArrayList(LspDiagnostic),
) void {
    const module = analysis.module orelse return;
    const source = module.source;

    for (module.symbols.items, 0..) |sym, i| {
        if (!analysis.isUnusedBindingReportable(@intCast(i))) continue;

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
