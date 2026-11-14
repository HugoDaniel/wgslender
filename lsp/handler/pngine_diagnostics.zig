//! Composed diagnostic projection for pngine shader projects
//! (pngine-shaders phase 03, Task 2).
//!
//! A root analysis speaks in assembled coordinates. This module converts
//! every validator entry through `Assembled.toOrigin` and then through the
//! origin part's own document text, so an editor never sees an assembled
//! offset or a range that belongs to another file.
//!
//! ## Rules
//!
//! - A primary entry is returned only when its mapped origin is the
//!   requested document. An entry whose primary origin is another file
//!   belongs in that file's report; it is not degraded for this one.
//! - An entry with no honest author range (a cross-part range, a blanked
//!   directive, or an inline `:code` part with no file URI yet) is dropped
//!   and the report records one degradation. `Report.finish` appends a
//!   single `P0001` for the whole report, never one per dropped entry.
//! - Related information is projected independently: each entry keeps its
//!   own part's URI and range. A relation that cannot be mapped is omitted
//!   rather than clamped to a different file.
//! - A textual quick fix survives only when the primary range and the fix
//!   range both resolve into the requested document. Otherwise the
//!   diagnostic stays and the fix is withheld: applying an assembled-coordinate
//!   or cross-file edit to the author's buffer would rewrite the wrong bytes.
//!
//! The projector reads only the Store's already-resolved author texts. It
//! never parses or rescans assembled text; all identity comes from the
//! phase-02 segments.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");
const pngine_path = @import("pngine_path");
const Handler = @import("../Handler.zig");

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;
const WgslDiagnostic = wgslender.Diagnostic;
const LspDiagnostic = Handler.LspDiagnostic;
const LspRelatedInfo = Handler.LspRelatedInfo;

const Allocator = std.mem.Allocator;

/// Options accepted by `Handler.validatePngineDocument`. Task 2 projects
/// validator entries only; Task 4 extends this with lint/M-rule switches.
pub const ValidateOptions = struct {
    include_minify_lints: bool = false,
};

/// One composed report for one requested document. `add` may be called
/// with the entries of every containing root; `finish` hands the caller a
/// single owned LSP diagnostic slice.
pub const Report = if (pngine_support) ReportImpl else struct {};

/// Validate a document in every root that contains it. Returns only the
/// entries whose primary origin is `uri`, plus at most one `P0001` when an
/// entry could not be projected. Caller frees with `Handler.freeDiagnostics`.
pub fn validateDocument(
    handler: *Handler,
    uri: []const u8,
    options: ValidateOptions,
) ![]LspDiagnostic {
    if (comptime pngine_support) {
        return validateSupported(handler, uri, options);
    } else {
        return error.PngineUnsupported;
    }
}

fn validateSupported(
    handler: *Handler,
    uri: []const u8,
    options: ValidateOptions,
) ![]LspDiagnostic {
    _ = options; // Task 4 adds lint; Task 2 is validator projection.

    const store = handler.pngine_store orelse return error.PngineStoreUnbound;
    var memberships = try store.membershipsFor(uri);
    defer memberships.deinit(handler.gpa);
    if (memberships.items.len == 0) return handler.gpa.alloc(LspDiagnostic, 0);

    var report = ReportImpl.init(handler.gpa, store, uri, memberships.items);
    defer report.deinit();

    // A file can be reachable through several memberships of the same root
    // (for example a file named twice in one program). Analyse and project
    // each root once so a report never carries the same entry twice.
    var roots: std.ArrayList(Pngine.RootId) = .empty;
    defer roots.deinit(handler.gpa);
    for (memberships.items) |membership| {
        for (membership.containing_roots) |index| {
            const id: Pngine.RootId = .{ .program = membership.program, .index = index };
            if (!containsRoot(roots.items, id)) try roots.append(handler.gpa, id);
        }
    }

    for (roots.items) |root| {
        // `assembled` is borrowed from the Store. Read it only inside this
        // iteration, through the pointer `analyzeRoot` just returned; a
        // later root analysis may replace the Store's unit.
        const analysis = try handler.analyzeRoot(root);
        for (analysis.result.diagnostics.diagnostics.items) |*entry| {
            try report.add(analysis.assembled, entry);
        }
    }

    return report.finish();
}

fn containsRoot(roots: []const Pngine.RootId, id: Pngine.RootId) bool {
    for (roots) |root| {
        if (root.program == id.program and root.index == id.index) return true;
    }
    return false;
}

const OriginDoc = struct {
    /// URI emitted for this origin. Requested-document parts use the
    /// caller's spelling; other file-backed parts get a canonical file URI.
    uri: []u8,
    text: Pngine.Types.SourceText,
    mapper: Handler.PositionMapper,

    fn deinit(self: *OriginDoc, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        self.text.deinit(gpa);
        gpa.free(self.uri);
    }
};

const ReportImpl = struct {
    gpa: Allocator,
    store: *Pngine.Store,
    requested_uri: []const u8,
    /// The PartIds whose `:file` names the requested document. Filtering
    /// on identity (not a re-derived path string) keeps symlink/URI
    /// spelling from deciding which report a diagnostic belongs to.
    requested_parts: []const Pngine.OriginKey,
    docs: std.AutoHashMapUnmanaged(Pngine.OriginKey, OriginDoc) = .empty,
    diags: std.ArrayList(LspDiagnostic) = .empty,
    /// Set when at least one entry had no honest author primary range.
    dropped: bool = false,

    pub fn init(
        gpa: Allocator,
        store: *Pngine.Store,
        requested_uri: []const u8,
        memberships: []const Pngine.Types.Membership,
    ) ReportImpl {
        var requested_parts = std.ArrayList(Pngine.OriginKey).empty;
        defer requested_parts.deinit(gpa);
        for (memberships) |membership| {
            if (!containsPart(requested_parts.items, membership.part)) {
                requested_parts.append(gpa, membership.part) catch {};
            }
        }
        return .{
            .gpa = gpa,
            .store = store,
            .requested_uri = requested_uri,
            .requested_parts = requested_parts.toOwnedSlice(gpa) catch &.{},
        };
    }

    pub fn deinit(self: *ReportImpl) void {
        for (self.diags.items) |diag| Handler.Diagnostics.freeSingleDiagnostic(self.gpa, diag);
        self.diags.deinit(self.gpa);
        var it = self.docs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        if (self.requested_parts.len > 0) self.gpa.free(@constCast(self.requested_parts));
    }

    pub fn add(self: *ReportImpl, assembled: *const Pngine.Assembled, entry: *const WgslDiagnostic.Entry) !void {
        if (try self.project(assembled, entry)) |diag| {
            try self.diags.append(self.gpa, diag);
        }
    }

    pub fn finish(self: *ReportImpl) ![]LspDiagnostic {
        if (self.dropped) try self.diags.append(self.gpa, self.degradedDiagnostic());
        const owned = try self.diags.toOwnedSlice(self.gpa);
        self.diags = .empty;
        return owned;
    }

    fn project(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        entry: *const WgslDiagnostic.Entry,
    ) !?LspDiagnostic {
        const mapped = assembled.toOrigin(.{
            .start = entry.range.start.offset,
            .end = entry.range.end.offset,
        }) orelse {
            self.dropped = true;
            return null;
        };

        const doc = (try self.docFor(mapped.origin)) orelse {
            // An inline `:code` part has author text but no URI until phase
            // 04 introduces the virtual document. No honest primary range
            // exists for an editor in this phase.
            self.dropped = true;
            return null;
        };
        if (!self.isRequested(mapped.origin)) return null;
        const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse {
            self.dropped = true;
            return null;
        };

        const related = try self.projectRelated(assembled, entry);
        errdefer freeRelated(self.gpa, related);

        const message = try dupeOrEmpty(self.gpa, entry.message);
        errdefer if (message.len > 0) self.gpa.free(message);

        const spec_url = try buildSpecUrl(self.gpa, entry);
        errdefer if (spec_url.len > 0) self.gpa.free(spec_url);

        const data = try self.projectData(assembled, entry);

        return .{
            .range = range,
            .severity = switch (entry.severity) {
                .@"error" => .@"error",
                .warning => .warning,
                .hint => .hint,
                .note => .information,
                else => .information,
            },
            .message = message,
            .code = entry.code,
            .spec_url = spec_url,
            .related = related,
            .data = data,
        };
    }

    fn projectRelated(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        entry: *const WgslDiagnostic.Entry,
    ) ![]const LspRelatedInfo {
        if (entry.related.len == 0) return &.{};

        var list: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer {
            for (list.items) |item| freeRelatedItem(self.gpa, item);
            list.deinit(self.gpa);
        }

        for (entry.related) |rel| {
            const mapped = assembled.toOrigin(.{
                .start = rel.range.start.offset,
                .end = rel.range.end.offset,
            }) orelse continue;
            const doc = (try self.docFor(mapped.origin)) orelse continue;
            const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse continue;

            const uri = try self.gpa.dupe(u8, doc.uri);
            errdefer self.gpa.free(uri);
            const message = try dupeOrEmpty(self.gpa, rel.message);
            errdefer if (message.len > 0) self.gpa.free(message);

            try list.append(self.gpa, .{ .uri = uri, .range = range, .message = message });
        }

        if (list.items.len == 0) {
            list.deinit(self.gpa);
            return &.{};
        }
        return try list.toOwnedSlice(self.gpa);
    }

    /// Convert a quick fix only when the primary reached the requested
    /// document (checked by the caller) and the fix's own assembled range
    /// maps to the requested document as well. `.lint_fix` data without a
    /// byte-range `Entry.fix` cannot be verified against the assembled
    /// unit, so it is withheld rather than trusted as author coordinates.
    fn projectData(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        entry: *const WgslDiagnostic.Entry,
    ) !WgslDiagnostic.QuickFixHint {
        if (entry.fix) |fix| {
            const hint = try self.projectFix(assembled, fix) orelse return .none;
            return hint;
        }
        return switch (entry.data) {
            .lint_fix => .none,
            else => Handler.Diagnostics.dupeQuickFixHint(self.gpa, entry.data),
        };
    }

    fn projectFix(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        fix: *const WgslDiagnostic.Fix,
    ) !?WgslDiagnostic.QuickFixHint {
        const mapped = assembled.toOrigin(.{
            .start = fix.range.start.offset,
            .end = fix.range.end.offset,
        }) orelse return null;
        if (!self.isRequested(mapped.origin)) return null;
        const doc = (try self.docFor(mapped.origin)) orelse return null;
        const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse return null;

        const text = try dupeOrEmpty(self.gpa, fix.text);
        return .{ .lint_fix = .{
            .start_line = range.start.line,
            .start_character = range.start.character,
            .end_line = range.end.line,
            .end_character = range.end.character,
            .text = text,
        } };
    }

    fn degradedDiagnostic(self: *const ReportImpl) LspDiagnostic {
        const zero: Handler.Position = .{ .line = 0, .character = 0 };
        return .{
            .range = .{ .start = zero, .end = zero },
            .severity = .warning,
            .message = dupeOrEmpty(
                self.gpa,
                "pngine project context is incomplete: a diagnostic could not be projected " ++
                    "to an author file; only local syntax is reported",
            ) catch "",
            .code = WgslDiagnostic.Code.pngine_context_incomplete,
        };
    }

    fn isRequested(self: *const ReportImpl, origin: Pngine.OriginKey) bool {
        return containsPart(self.requested_parts, origin);
    }

    /// Resolve one origin part's current author text and URI. Inline parts
    /// return null: there is no URI an editor can open before phase 04.
    /// The returned pointer is stable only until the next `docFor` call.
    fn docFor(self: *ReportImpl, origin: Pngine.OriginKey) !?*OriginDoc {
        if (self.docs.getPtr(origin)) |doc| return doc;

        const part = self.store.part(origin) orelse return null;
        const file = switch (part.origin) {
            .file => |source| source,
            .inline_code => return null,
        };
        const program = self.store.program(origin.program) orelse return null;

        const path = try resolvePath(self.gpa, program.document_path, file.path);
        defer self.gpa.free(path);

        const uri = if (self.isRequested(origin))
            try self.gpa.dupe(u8, self.requested_uri)
        else
            try pngine_path.pathToFileUri(self.gpa, path);
        errdefer self.gpa.free(uri);

        var text = self.store.textForPart(origin) catch |err| switch (err) {
            error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => return null,
            else => return err,
        };
        errdefer text.deinit(self.gpa);

        var mapper = try Handler.PositionMapper.init(self.gpa, text.text);
        errdefer mapper.deinit(self.gpa);

        const gop = try self.docs.getOrPut(self.gpa, origin);
        if (gop.found_existing) {
            mapper.deinit(self.gpa);
            text.deinit(self.gpa);
            self.gpa.free(uri);
            return gop.value_ptr;
        }
        gop.value_ptr.* = .{ .uri = uri, .text = text, .mapper = mapper };
        return gop.value_ptr;
    }
};

fn containsPart(parts: []const Pngine.OriginKey, id: Pngine.OriginKey) bool {
    for (parts) |part| {
        if (part.program == id.program and part.index == id.index) return true;
    }
    return false;
}

/// Resolve a `:file` value exactly as the Store does for membership:
/// relative to the program's document, then lexically normalized.
fn resolvePath(allocator: Allocator, document_path: []const u8, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return pngine_path.normalizeLexical(allocator, relative);
    }
    const dir = std.fs.path.dirname(document_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, relative });
    defer allocator.free(joined);
    return pngine_path.normalizeLexical(allocator, joined);
}

fn dupeOrEmpty(gpa: Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return gpa.dupe(u8, value);
}

fn freeRelatedItem(gpa: Allocator, item: LspRelatedInfo) void {
    if (item.uri.len > 0) gpa.free(item.uri);
    if (item.message.len > 0) gpa.free(item.message);
}

fn freeRelated(gpa: Allocator, related: []const LspRelatedInfo) void {
    if (related.len == 0) return;
    for (related) |item| freeRelatedItem(gpa, item);
    gpa.free(related);
}

fn buildSpecUrl(gpa: Allocator, entry: *const WgslDiagnostic.Entry) ![]const u8 {
    if (entry.code.len == 0 or entry.spec_ref.len == 0) return "";
    const base = Handler.Diagnostics.wgsl_spec_base;
    const url = try gpa.alloc(u8, base.len + entry.spec_ref.len);
    @memcpy(url[0..base.len], base);
    @memcpy(url[base.len..], entry.spec_ref);
    return url;
}
