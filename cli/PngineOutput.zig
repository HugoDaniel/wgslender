//! Composed CLI validate/lint output (pngine-shaders phase 05, Task 2).
//!
//! This module is the native CLI driver for a selected pngine project. It
//! runs the shared per-root analysis (`Pngine.Analysis`) and the shared
//! diagnostic projector (`Pngine.Projection`) over every selected root,
//! then renders either the existing human format (with origin files) or
//! the extended JSON envelopes. No project text is opened here: reads go
//! through the Store's `SourceProvider`, and no assembled module is ever
//! printed or written.

const std = @import("std");
const build_options = @import("build_options");
const wgslender = @import("wgslender");
const PngineSelection = @import("PngineSelection");

const pngine_support = build_options.pngine_support;
const pngine = if (pngine_support) wgslender.Pngine else void;

const Allocator = std.mem.Allocator;
const Diagnostic = wgslender.Diagnostic;

pub const Command = enum { validate, lint };

pub const Format = enum { text, json, stylish };

pub const Config = struct {
    format: Format = .text,
    strict: bool = false,
    line_offset: i32 = 0,
    quiet: bool = false,
    max_warnings: ?u32 = null,
    lint_extends: []const []const u8 = &.{},
    lint_rules: []const wgslender.Linter.Options.RuleOverride = &.{},
    report_unused_disable_directives: bool = false,
    input_path: ?[]const u8 = null,
};

/// One completed composed run. Owns the shared projector and its borrowed
/// diagnostic views; call `deinit` exactly once.
pub const Report = if (pngine_support) ReportImpl else struct {};

const ReportImpl = struct {
    gpa: Allocator,
    store: *PngineSelection.Store,
    projection: pngine.Projection.Report,
    result: pngine.Projection.Result,
    program: pngine.Types.ProgramId,
    input_origin: ?pngine.OriginKey,
    config: Config,
    error_count: u32 = 0,
    warning_count: u32 = 0,
    fixable_count: u32 = 0,
    valid: bool = false,
    exit_code: u8 = 0,

    pub fn deinit(self: *ReportImpl, gpa: Allocator) void {
        self.result.deinit(gpa);
        self.projection.deinit();
        self.* = undefined;
    }

    pub fn items(self: *const ReportImpl) []const pngine.Projection.DiagnosticOut {
        return self.result.items;
    }

    pub fn originPath(self: *ReportImpl, origin: pngine.OriginKey) ?[]const u8 {
        return self.projection.originPath(origin);
    }

    /// Human `file:line:col` text for every emitted diagnostic. Standalone
    /// invocations never reach this module, so their bytes are untouched.
    pub fn renderText(self: *ReportImpl, gpa: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const view = try self.buildView(alloc, self.config.quiet and self.config.format != .json);

        var out: std.ArrayList(u8) = .empty;
        switch (self.config.format) {
            .json => unreachable,
            .text => try renderPlain(gpa, &out, view.entries),
            .stylish => try renderStylish(gpa, &out, view.entries),
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn renderValidateJson(self: *ReportImpl, gpa: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const view = try self.buildView(alloc, false);

        const entries = try alloc.alloc(Diagnostic.Entry, view.entries.len);
        for (view.entries, 0..) |item, index| entries[index] = item.entry;

        var buf: std.ArrayList(u8) = .empty;
        try wgslender.api_json.writeValidateEnvelope(
            &buf,
            gpa,
            self.valid,
            entries,
            self.error_count,
            self.warning_count,
        );
        try buf.append(gpa, '\n');
        return buf.toOwnedSlice(gpa);
    }

    pub fn renderLintJson(self: *ReportImpl, gpa: Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const view = try self.buildView(alloc, false);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(gpa, "{\"results\":[");

        var any_group = false;
        var first_group = true;
        var seen: std.StringHashMapUnmanaged(usize) = .{};
        var groups: std.ArrayList(Group) = .empty;
        for (view.entries) |item| {
            const key = groupKey(self, item);
            const gop = try seen.getOrPut(alloc, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = groups.items.len;
                try groups.append(alloc, .{ .key = key });
            }
            try groups.items[gop.value_ptr.*].entries.append(alloc, item);
        }

        for (groups.items) |*group| {
            if (!first_group) try out.append(gpa, ',');
            first_group = false;
            any_group = true;

            var group_errors: u32 = 0;
            var group_warnings: u32 = 0;
            var group_fixable: u32 = 0;
            for (group.entries.items) |item| {
                switch (item.entry.severity) {
                    .@"error" => group_errors += 1,
                    .warning => group_warnings += 1,
                    else => {},
                }
                if (item.entry.fix != null) group_fixable += 1;
            }

            var filtered: std.ArrayList(Diagnostic.Entry) = .empty;
            for (group.entries.items) |item| {
                if (self.config.quiet and item.entry.severity != .@"error") continue;
                try filtered.append(alloc, item.entry);
            }

            try wgslender.api_json.writeLintFileResult(
                &out,
                gpa,
                group.key,
                filtered.items,
                group_errors,
                group_warnings,
                group_fixable,
            );
        }

        // The standalone lint path emits one result even with no findings.
        // Preserve that shape for a project run that found nothing.
        if (!any_group) {
            const key = self.projectPath() orelse self.config.input_path orelse "<stdin>";
            try wgslender.api_json.writeLintFileResult(
                &out,
                gpa,
                key,
                &.{},
                0,
                0,
                0,
            );
        }

        try out.appendSlice(gpa, "],\"errorCount\":");
        try Diagnostic.appendInt(&out, gpa, self.error_count);
        try out.appendSlice(gpa, ",\"warningCount\":");
        try Diagnostic.appendInt(&out, gpa, self.warning_count);
        try out.appendSlice(gpa, ",\"fixableCount\":");
        try Diagnostic.appendInt(&out, gpa, self.fixable_count);
        try out.appendSlice(gpa, "}\n");
        return out.toOwnedSlice(gpa);
    }

    /// The fixed text for the input part only. Returns null when the run has
    /// no input part (for example a stdin invocation without an overlay).
    /// Fixes attached to any other part are never applied.
    pub fn fixedInput(self: *ReportImpl, gpa: Allocator) !?[]u8 {
        const origin = self.input_origin orelse return null;
        const source = self.projection.originText(origin) orelse return null;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var fixes: std.ArrayList(Diagnostic.Fix) = .empty;
        for (self.result.items) |item| {
            const primary = item.origin orelse continue;
            if (!sameOrigin(primary, origin)) continue;
            const fix = item.fix orelse continue;
            if (!sameOrigin(fix.origin, origin)) continue;

            const start = self.projection.originPosition(origin, fix.range.start) orelse continue;
            const end = self.projection.originPosition(origin, fix.range.end) orelse continue;
            try fixes.append(alloc, .{
                .range = .{
                    .start = .{
                        .offset = fix.range.start,
                        .line = applyLineOffset(start.line, self.config.line_offset),
                        .column = start.column,
                    },
                    .end = .{
                        .offset = fix.range.end,
                        .line = applyLineOffset(end.line, self.config.line_offset),
                        .column = end.column,
                    },
                },
                .text = fix.text,
            });
        }

        // Point at the stable slice after all appends: an ArrayList may have
        // reallocated during collection.
        const entries = try alloc.alloc(Diagnostic.Entry, fixes.items.len);
        for (fixes.items, 0..) |*fix, index| entries[index] = .{ .fix = fix };

        const fixed = try wgslender.Linter.Fixer.apply(alloc, source, entries);
        return try gpa.dupe(u8, fixed.fixed);
    }

    fn projectPath(self: *const ReportImpl) ?[]const u8 {
        return self.projection.projectPath(self.program);
    }

    fn buildView(self: *ReportImpl, alloc: Allocator, quiet: bool) !View {
        var entries: std.ArrayList(ViewEntry) = .empty;
        var error_count: u32 = 0;
        var warning_count: u32 = 0;
        var fixable_count: u32 = 0;

        for (self.result.items) |item| {
            switch (item.severity) {
                .@"error" => error_count += 1,
                .warning => warning_count += 1,
                else => {},
            }
            if (item.fix != null) fixable_count += 1;
            if (quiet and item.severity != .@"error") continue;
            try entries.append(alloc, try self.buildEntry(alloc, item));
        }

        return .{
            .entries = entries.items,
            .error_count = error_count,
            .warning_count = warning_count,
            .fixable_count = fixable_count,
        };
    }

    fn buildEntry(self: *ReportImpl, alloc: Allocator, item: pngine.Projection.DiagnosticOut) !ViewEntry {
        var entry: Diagnostic.Entry = .{
            .severity = item.severity,
            .code = item.code,
            .message = item.message,
            .spec_ref = item.spec_ref,
            .source = item.source,
            .data = item.data,
        };

        const prefix: []const u8 = if (item.origin) |origin|
            self.projection.originPath(origin) orelse self.config.input_path orelse "<stdin>"
        else
            self.projection.projectPath(item.program orelse self.program) orelse
                self.config.input_path orelse "<stdin>";

        if (item.origin) |origin| {
            const start = self.projection.originPosition(origin, item.range.start) orelse
                pngine.Projection.Position{ .line = 1, .column = 1 };
            const end = self.projection.originPosition(origin, item.range.end) orelse start;
            entry.range = .{
                .start = .{
                    .offset = item.range.start,
                    .line = applyLineOffset(start.line, self.config.line_offset),
                    .column = start.column,
                },
                .end = .{
                    .offset = item.range.end,
                    .line = applyLineOffset(end.line, self.config.line_offset),
                    .column = end.column,
                },
            };
            entry.origin = .{
                .file = prefix,
                .project = self.projection.projectPath(origin.program) orelse "",
                .root = if (item.roots.len > 0)
                    self.projection.rootName(item.roots[0]) orelse ""
                else
                    "",
            };
        } else {
            entry.range.start = .{ .line = applyLineOffset(1, self.config.line_offset), .column = 1 };
            entry.range.end = entry.range.start;
        }

        if (item.related.len > 0) {
            const related = try alloc.alloc(Diagnostic.RelatedInfo, item.related.len);
            for (item.related, 0..) |relation, index| {
                const target = relation.target;
                const path: []const u8, const position = switch (target) {
                    .author => |author| .{
                        self.projection.originPath(author.origin) orelse "",
                        self.projection.originPosition(author.origin, author.range.start) orelse
                            pngine.Projection.Position{ .line = 1, .column = 1 },
                    },
                    .project => |project| .{
                        self.projection.projectPath(project.program) orelse "",
                        self.projection.projectPosition(project.program, project.range.start) orelse
                            pngine.Projection.Position{ .line = 1, .column = 1 },
                    },
                };
                related[index] = .{
                    .file = path,
                    .range = .{
                        .start = .{
                            .offset = switch (target) {
                                .author => |author| author.range.start,
                                .project => |project| project.range.start,
                            },
                            .line = applyLineOffset(position.line, self.config.line_offset),
                            .column = position.column,
                        },
                    },
                    .message = relation.message,
                };
            }
            entry.related = related;
        }

        if (item.fix) |fix| {
            const start = self.projection.originPosition(fix.origin, fix.range.start) orelse
                pngine.Projection.Position{ .line = 1, .column = 1 };
            const end = self.projection.originPosition(fix.origin, fix.range.end) orelse start;
            const fix_ptr = try alloc.create(Diagnostic.Fix);
            fix_ptr.* = .{
                .range = .{
                    .start = .{
                        .offset = fix.range.start,
                        .line = applyLineOffset(start.line, self.config.line_offset),
                        .column = start.column,
                    },
                    .end = .{
                        .offset = fix.range.end,
                        .line = applyLineOffset(end.line, self.config.line_offset),
                        .column = end.column,
                    },
                },
                .text = fix.text,
            };
            entry.fix = fix_ptr;
        }

        return .{ .entry = entry, .prefix = prefix };
    }
};

const ViewEntry = struct {
    entry: Diagnostic.Entry,
    prefix: []const u8,
};

const View = struct {
    entries: []ViewEntry,
    error_count: u32,
    warning_count: u32,
    fixable_count: u32,
};

const Group = struct {
    key: []const u8,
    entries: std.ArrayList(ViewEntry) = .empty,
};

fn groupKey(self: *const ReportImpl, item: ViewEntry) []const u8 {
    if (item.entry.origin.file.len > 0) return item.entry.origin.file;
    return self.projectPath() orelse self.config.input_path orelse "<stdin>";
}

fn applyLineOffset(line: u32, offset: i32) u32 {
    const shifted: i64 = @as(i64, line) + offset;
    return if (shifted >= 1) @intCast(shifted) else 1;
}

fn renderPlain(gpa: Allocator, out: *std.ArrayList(u8), entries: []const ViewEntry) !void {
    for (entries) |item| {
        try Diagnostic.writeTextLine(out, gpa, &item.entry, item.prefix);
        try appendRelated(out, gpa, item.entry.related);
    }
}

fn renderStylish(gpa: Allocator, out: *std.ArrayList(u8), entries: []const ViewEntry) !void {
    if (entries.len == 0) return;

    var seen: std.StringHashMapUnmanaged(usize) = .{};
    var groups: std.ArrayList(Group) = .empty;
    for (entries) |item| {
        const gop = try seen.getOrPut(gpa, item.prefix);
        if (!gop.found_existing) {
            gop.value_ptr.* = groups.items.len;
            try groups.append(gpa, .{ .key = item.prefix });
        }
        try groups.items[gop.value_ptr.*].entries.append(gpa, item);
    }

    for (groups.items) |group| {
        try out.appendSlice(gpa, "\n");
        try out.appendSlice(gpa, group.key);
        try out.append(gpa, '\n');
        for (group.entries.items) |item| {
            var scratch: [32]u8 = undefined;
            try out.appendSlice(gpa, "  ");
            const ls = std.fmt.bufPrint(&scratch, "{d}:{d}", .{
                item.entry.range.start.line,
                item.entry.range.start.column,
            }) catch "";
            try out.appendSlice(gpa, ls);
            const pad = if (ls.len < 8) 8 - ls.len else 1;
            var i: usize = 0;
            while (i < pad) : (i += 1) try out.append(gpa, ' ');
            try out.appendSlice(gpa, item.entry.severity.string());
            try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, item.entry.message);
            if (item.entry.code.len > 0) {
                try out.appendSlice(gpa, "  ");
                try out.appendSlice(gpa, item.entry.code);
            }
            try out.append(gpa, '\n');
            try appendRelated(out, gpa, item.entry.related);
        }
    }
}

fn appendRelated(out: *std.ArrayList(u8), gpa: Allocator, related: []const Diagnostic.RelatedInfo) !void {
    for (related) |relation| {
        try out.appendSlice(gpa, "  --> ");
        if (relation.file.len > 0) {
            try out.appendSlice(gpa, relation.file);
            try out.append(gpa, ':');
            try Diagnostic.appendInt(out, gpa, relation.range.start.line);
            try out.append(gpa, ':');
            try Diagnostic.appendInt(out, gpa, relation.range.start.column);
            try out.appendSlice(gpa, ": ");
        }
        try out.appendSlice(gpa, relation.message);
        try out.append(gpa, '\n');
    }
}

/// Run one composed validate/lint over the selected roots.
pub fn run(
    gpa: Allocator,
    store: *PngineSelection.Store,
    program: pngine.Types.ProgramId,
    input_part: ?pngine.Types.PartId,
    roots: []const pngine.RootId,
    command: Command,
    config: Config,
) !Report {
    if (comptime !pngine_support) return error.PngineUnsupported;

    var shader_roots: std.ArrayList(pngine.RootId) = .empty;
    defer shader_roots.deinit(gpa);
    var pass_roots: std.ArrayList(pngine.RootId) = .empty;
    defer pass_roots.deinit(gpa);

    for (roots) |root| {
        const part = store.part(root) orelse continue;
        switch (part.kind) {
            .shader_module => try shader_roots.append(gpa, root),
            .pass => try pass_roots.append(gpa, root),
            .wgsl => {},
        }
    }

    var input_origin: ?pngine.OriginKey = if (input_part) |part| .{
        .program = part.program,
        .index = part.index,
    } else null;
    if (input_origin == null and roots.len == 1) {
        input_origin = .{ .program = roots[0].program, .index = roots[0].index };
    }

    var projection = try pngine.Projection.Report.init(gpa, store, .{
        .roots = shader_roots.items,
    });
    errdefer projection.deinit();
    projection.semantic_root_count = shader_roots.items.len;

    var any_shader_ok = false;
    for (shader_roots.items) |root| {
        const assembled = store.assembleRoot(root) catch |err| {
            switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try projection.addAssemblyFailure(root, err);
                    continue;
                },
            }
        };

        var analysis = try pngine.Analysis.analyze(gpa, assembled, .{
            .strict_mode = command == .validate and config.strict,
            .line_offset = config.line_offset,
        });
        defer analysis.deinit();
        any_shader_ok = true;

        for (analysis.diagnostics.diagnostics.items) |*entry| {
            try projection.addFromRoot(assembled, root, entry);
        }
        try projection.checkRequirements(root, analysis.module, null);
        try projection.noteRootAnalyzed(root, analysis.module != null);

        if (command == .lint) {
            var lint_result = try wgslender.Linter.run(gpa, &analysis, .{
                .extends = config.lint_extends,
                .rules = config.lint_rules,
                .line_offset = config.line_offset,
                .report_unused_disable_directives = config.report_unused_disable_directives,
            });
            defer lint_result.deinit(gpa);
            for (lint_result.diagnostics.items()) |*entry| {
                try projection.addLintFromRoot(assembled, root, entry);
            }
        }
    }

    for (pass_roots.items) |root| try projection.addPassUnsupported(root);

    if (!any_shader_ok) {
        if (pass_roots.items.len == 0) {
            projection.addIncomplete(if (shader_roots.items.len == 0)
                "no shader-module root contains this file"
            else
                "no shader-module root could be assembled");
        }
        if (input_origin) |origin| {
            const only = [_]pngine.OriginKey{origin};
            try projection.addLocalSyntax(&only);
        }
    }

    const result = try projection.finish();

    var error_count: u32 = 0;
    var warning_count: u32 = 0;
    var fixable_count: u32 = 0;
    for (result.items) |item| {
        switch (item.severity) {
            .@"error" => error_count += 1,
            .warning => warning_count += 1,
            else => {},
        }
        if (item.fix != null) fixable_count += 1;
    }

    const valid = switch (command) {
        .validate => error_count == 0 and (!config.strict or warning_count == 0),
        .lint => error_count == 0 and
            (config.max_warnings == null or warning_count <= config.max_warnings.?),
    };

    return .{
        .gpa = gpa,
        .store = store,
        .projection = projection,
        .result = result,
        .program = program,
        .input_origin = input_origin,
        .config = config,
        .error_count = error_count,
        .warning_count = warning_count,
        .fixable_count = fixable_count,
        .valid = valid,
        .exit_code = if (valid) 0 else 1,
    };
}

fn sameOrigin(a: pngine.OriginKey, b: pngine.OriginKey) bool {
    return a.program == b.program and a.index == b.index;
}
