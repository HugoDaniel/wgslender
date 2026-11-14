//! Composed diagnostic projection for pngine shader projects
//! (pngine-shaders phase 03, Tasks 2–4; shared engine extracted in phase 05,
//! Task 2).
//!
//! The projection, multi-root merge, graph-error reporting, requirement
//! checks, and whole-unit lint policy live in `pngine.Projection`, shared
//! with the native CLI. This file is the LSP adapter: it drives per-root
//! analysis through the Handler cache, supplies the LSP's configured lint
//! packs and minify estimate, then converts neutral author-byte findings
//! into LSP ranges/URIs for one requested document.
//!
//! Rules preserved from phase 03:
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
//!   range both resolve into the requested document.
//! - Validator entries from every containing shader-module root are unioned
//!   and deduplicated by `(mapped author range, code, original message)` in
//!   first-seen order. A group that appeared in more than one root carries
//!   one related entry per failing root (its `.sjon` root form).
//! - `E0100` is rewritten only on the composed path.
//! - Assembly failures become `P0002`, an unfilled `:requires` hole becomes
//!   `P0003`, and a pass-only context becomes `P0004`.
//! - `W0001`/`W0002`/`W0003` are emitted only when every lint-capable root
//!   that contains the requested file also produced them. `M0500` is disabled
//!   when more than one shader-module root contains the requested part.
//! - A lint quick fix survives only when its whole edit range maps to the
//!   requested author file and every root offering that fix agrees on the
//!   replacement.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");
const pngine_path = @import("pngine_path");
const Handler = @import("../Handler.zig");
const Diagnostics = Handler.Diagnostics;

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;
const Projection = if (pngine_support) Pngine.Projection else struct {};
const WgslDiagnostic = wgslender.Diagnostic;
const LspDiagnostic = Handler.LspDiagnostic;
const LspRelatedInfo = Handler.LspRelatedInfo;

const Allocator = std.mem.Allocator;

/// Options accepted by `Handler.validatePngineDocument`. `include_minify_lints`
/// mirrors the standalone cheap/full split: general packs always run when the
/// LSP lint setting is on, while the `@wgslender/minify` pack (and the
/// estimator-backed M-rules) only join on the full path.
pub const ValidateOptions = struct {
    include_minify_lints: bool = false,
};

/// One composed report for one requested document. `add` may be called with
/// the entries of every containing root; `finish` hands the caller a single
/// owned LSP diagnostic slice.
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
    const store = handler.pngine_store orelse return error.PngineStoreUnbound;
    var memberships = try store.membershipsFor(uri);
    defer memberships.deinit(handler.gpa);
    if (memberships.items.len == 0) return handler.gpa.alloc(LspDiagnostic, 0);

    var report = ReportImpl.init(handler.gpa, store, uri, memberships.items);
    defer report.deinit();

    // Resolve the same config contributions the standalone path builds,
    // once per request. The magic-comment layer belongs to the requested
    // author document, exactly as it does for `validateDocument*`.
    const lint_active = handler.lintEnabled();
    const eff_minify = handler.effectiveMinifyFor(uri);
    const minify_active = options.include_minify_lints and eff_minify.lintsActive();
    // A module-size finding is a claim about one assembled root. When the
    // requested part is shared, no single root's size describes it, so the
    // rule is disabled rather than allowed to pick one.
    const suppress_size = report.requestRootCount() > 1;

    // A file can be reachable through several memberships of the same root
    // (for example a file named twice in one program). Analyse and project
    // each root once so a report never carries the same entry twice.
    var shader_roots: std.ArrayList(Pngine.RootId) = .empty;
    defer shader_roots.deinit(handler.gpa);
    var pass_roots: std.ArrayList(Pngine.RootId) = .empty;
    defer pass_roots.deinit(handler.gpa);

    for (memberships.items) |membership| {
        for (membership.containing_roots) |index| {
            const id: Pngine.RootId = .{ .program = membership.program, .index = index };
            const part = store.part(id) orelse continue;
            switch (part.kind) {
                // Passes are roots for membership only. Their generated
                // prelude is not reproduced, so no semantic claim is made.
                .pass => try appendRoot(handler.gpa, &pass_roots, id),
                .shader_module => try appendRoot(handler.gpa, &shader_roots, id),
                .wgsl => {},
            }
        }
    }

    report.semantic_root_count = shader_roots.items.len;

    var any_shader_ok = false;
    for (shader_roots.items) |root| {
        // `assembled` is borrowed from the Store. Read it only inside this
        // iteration, through the pointer `analyzeRoot` just returned; a
        // later root analysis may replace the Store's unit.
        const analysis = handler.analyzeRoot(root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.PngineStoreUnbound => return err,
            else => {
                try report.addAssemblyFailure(root, err);
                continue;
            },
        };
        any_shader_ok = true;

        for (analysis.result.diagnostics.diagnostics.items) |*entry| {
            try report.addFromRoot(analysis.assembled, root, entry);
        }
        try report.checkRequirements(root, analysis.result.module);

        // Liveness intersection is judged only among roots whose assembled
        // module actually parsed; a root that cannot produce a module
        // cannot prove a declaration unused or dead.
        try report.noteRootAnalyzed(root, analysis.result.module != null);
        if (lint_active or minify_active) {
            try lintRoot(
                handler,
                &report,
                analysis,
                root,
                uri,
                eff_minify,
                lint_active,
                minify_active,
                suppress_size,
            );
        }
    }

    // C29: a mixed pass/shader-module context keeps the shader-module
    // diagnostics and states the pass limitation explicitly. A pass-only
    // context has no semantic diagnostics to add at all.
    for (pass_roots.items) |root| try report.addPassUnsupported(root);

    if (!any_shader_ok) {
        // Requirement 7: local syntax plus one project diagnostic, never
        // standalone semantics for a fragment whose module context is
        // missing or broken. A pass-only context uses P0004 instead of
        // P0001 because the limitation is known, not incomplete.
        if (pass_roots.items.len == 0) {
            report.addIncomplete(if (shader_roots.items.len == 0)
                "no shader-module root contains this file"
            else
                "no shader-module root could be assembled");
        }
        try report.addLocalSyntax();
    }

    return report.finish();
}

fn appendRoot(
    gpa: Allocator,
    roots: *std.ArrayList(Pngine.RootId),
    id: Pngine.RootId,
) !void {
    for (roots.items) |root| {
        if (root.program == id.program and root.index == id.index) return;
    }
    try roots.append(gpa, id);
}

fn containsRoot(roots: []const Pngine.RootId, id: Pngine.RootId) bool {
    for (roots) |root| {
        if (root.program == id.program and root.index == id.index) return true;
    }
    return false;
}

fn containsOrigin(origins: []const Pngine.OriginKey, id: Pngine.OriginKey) bool {
    for (origins) |origin| {
        if (origin.program == id.program and origin.index == id.index) return true;
    }
    return false;
}

/// Run the configured lint packs against one cached root analysis and
/// project every entry through the same shared report the validator uses.
///
/// The extends/override construction is the standalone pipeline's, not a
/// second config path: `buildExtendsList` and `buildRuleOverrides` are
/// shared with `validateDocumentInner`. The only composed-path addition is
/// the disabled `M0500` override when the requested part has several root
/// contexts.
fn lintRoot(
    handler: *Handler,
    report: *ReportImpl,
    analysis: *Handler.RootAnalysis,
    root: Pngine.RootId,
    uri: []const u8,
    eff_minify: wgslender.MinifySettings.Effective,
    lint_active: bool,
    minify_active: bool,
    suppress_size: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(handler.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const extends = try Diagnostics.buildExtendsList(handler, alloc, lint_active, minify_active);
    const base_overrides = try Diagnostics.buildRuleOverrides(
        handler,
        alloc,
        eff_minify,
        handler.mangleExternalBindings(),
        minify_active,
    );

    var overrides: std.ArrayList(wgslender.Linter.Options.RuleOverride) = .empty;
    try overrides.appendSlice(alloc, base_overrides);
    if (suppress_size) try overrides.append(alloc, .{
        .id = "minify/shader-exceeds-size-budget",
        .severity = .disabled,
    });

    // M0500 can read the root's cached estimate, so the full path runs the
    // estimator at most once per root analysis. A suppressed size rule is
    // not worth estimating for.
    const cached_estimate: ?*const wgslender.MinifyEstimator.EstimateResult =
        if (minify_active and !suppress_size)
            handler.getRootMinifyEstimate(root, handler.estimatorOptionsFor(uri)) catch null
        else
            null;

    var result = try wgslender.Linter.run(handler.gpa, analysis.result, .{
        .extends = extends,
        .rules = overrides.items,
        .cached_minify_estimate = cached_estimate,
    });
    defer result.deinit(handler.gpa);

    for (result.diagnostics.items()) |entry| {
        try report.addLintFromRoot(analysis.assembled, root, &entry);
    }
}

/// LSP-side cache for one author origin's URI spelling, text and position
/// mapper. Text is borrowed from the shared projector's cache.
const OriginDoc = struct {
    uri: []u8,
    mapper: Handler.PositionMapper,

    fn deinit(self: *OriginDoc, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        gpa.free(self.uri);
    }
};

const ProjectDoc = struct {
    uri: []u8,
    mapper: Handler.PositionMapper,

    fn deinit(self: *ProjectDoc, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        gpa.free(self.uri);
    }
};

const RelatedLocation = struct {
    uri: []const u8,
    range: Handler.Range,
};

const ReportImpl = struct {
    gpa: Allocator,
    store: *Pngine.Store,
    requested_uri: []const u8,
    /// The PartIds whose `:file` names the requested document. Filtering on
    /// identity (not a re-derived path string) keeps symlink/URI spelling
    /// from deciding which report a diagnostic belongs to.
    requested_parts: []const Pngine.OriginKey,
    inner: Projection.Report,
    docs: std.AutoHashMapUnmanaged(Pngine.OriginKey, OriginDoc) = .empty,
    project_docs: std.AutoHashMapUnmanaged(Pngine.Types.ProgramId, *ProjectDoc) = .empty,
    /// Kept for the caller's root-count decision; `finish` copies it into
    /// the shared report before policy runs.
    semantic_root_count: usize = 0,

    pub fn init(
        gpa: Allocator,
        store: *Pngine.Store,
        requested_uri: []const u8,
        memberships: []const Pngine.Types.Membership,
    ) ReportImpl {
        var requested_parts = std.ArrayList(Pngine.OriginKey).empty;
        defer requested_parts.deinit(gpa);
        var request_roots = std.ArrayList(Pngine.RootId).empty;
        defer request_roots.deinit(gpa);
        for (memberships) |membership| {
            if (!containsOrigin(requested_parts.items, membership.part)) {
                requested_parts.append(gpa, membership.part) catch {};
            }
            for (membership.containing_roots) |index| {
                const id: Pngine.RootId = .{ .program = membership.program, .index = index };
                const part = store.part(id) orelse continue;
                if (part.kind != .shader_module) continue;
                if (!containsRoot(request_roots.items, id)) {
                    request_roots.append(gpa, id) catch {};
                }
            }
        }

        const parts = requested_parts.toOwnedSlice(gpa) catch &.{};
        const roots = request_roots.toOwnedSlice(gpa) catch &.{};
        defer if (roots.len > 0) gpa.free(roots);

        return .{
            .gpa = gpa,
            .store = store,
            .requested_uri = requested_uri,
            .requested_parts = parts,
            .inner = Projection.Report.init(gpa, store, .{
                .roots = roots,
                .fix_origins = parts,
            }) catch .{
                .gpa = gpa,
                .store = store,
                .roots = &.{},
                .fix_origins = null,
            },
        };
    }

    pub fn deinit(self: *ReportImpl) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        var project_it = self.project_docs.iterator();
        while (project_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.project_docs.deinit(self.gpa);
        self.inner.deinit();
        if (self.requested_parts.len > 0) self.gpa.free(@constCast(self.requested_parts));
    }

    pub fn requestRootCount(self: *const ReportImpl) usize {
        return self.inner.requestRootCount();
    }

    pub fn add(self: *ReportImpl, assembled: *const Pngine.Assembled, entry: *const WgslDiagnostic.Entry) !void {
        try self.inner.add(assembled, entry);
    }

    pub fn addFromRoot(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        root: Pngine.RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.inner.addFromRoot(assembled, root, entry);
    }

    pub fn addLintFromRoot(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        root: Pngine.RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.inner.addLintFromRoot(assembled, root, entry);
    }

    pub fn noteRootAnalyzed(self: *ReportImpl, root: Pngine.RootId, lint_capable: bool) !void {
        try self.inner.noteRootAnalyzed(root, lint_capable);
    }

    pub fn addAssemblyFailure(self: *ReportImpl, root: Pngine.RootId, err: anyerror) !void {
        try self.inner.addAssemblyFailure(root, err);
    }

    pub fn addPassUnsupported(self: *ReportImpl, root: Pngine.RootId) !void {
        try self.inner.addPassUnsupported(root);
    }

    pub fn addIncomplete(self: *ReportImpl, reason: []const u8) void {
        self.inner.addIncomplete(reason);
    }

    pub fn addLocalSyntax(self: *ReportImpl) !void {
        try self.inner.addLocalSyntax(self.requested_parts);
    }

    pub fn checkRequirements(self: *ReportImpl, root: Pngine.RootId, module: ?*wgslender.Ast.Module) !void {
        try self.inner.checkRequirements(root, module, self.requested_parts);
    }

    pub fn finish(self: *ReportImpl) ![]LspDiagnostic {
        self.inner.semantic_root_count = self.semantic_root_count;
        var result = try self.inner.finish();
        defer result.deinit(self.gpa);

        var out: std.ArrayList(LspDiagnostic) = .empty;
        errdefer {
            for (out.items) |diag| Diagnostics.freeSingleDiagnostic(self.gpa, diag);
            out.deinit(self.gpa);
        }

        for (result.items) |item| {
            const diag = self.buildDiagnostic(item) catch |err| switch (err) {
                error.SkipDiagnostic => continue,
                else => return err,
            };
            out.append(self.gpa, diag) catch |err| {
                Diagnostics.freeSingleDiagnostic(self.gpa, diag);
                return err;
            };
        }

        return out.toOwnedSlice(self.gpa);
    }

    fn buildDiagnostic(self: *ReportImpl, item: Projection.DiagnosticOut) !LspDiagnostic {
        const message = try dupeOrEmpty(self.gpa, item.message);
        errdefer if (message.len > 0) self.gpa.free(message);
        const related = try self.convertRelated(item.related);
        errdefer freeRelatedSlice(self.gpa, related);

        if (item.origin) |origin| {
            if (!containsOrigin(self.requested_parts, origin)) return error.SkipDiagnostic;
            const doc = (try self.docInfo(origin)) orelse return error.SkipDiagnostic;
            const range = doc.mapper.range(item.range.start, item.range.end) orelse zeroRange();
            const spec_url = try buildSpecUrl(self.gpa, item.code, item.spec_ref);
            errdefer if (spec_url.len > 0) self.gpa.free(spec_url);
            const data = try self.convertData(item);
            return .{
                .range = range,
                .severity = lspSeverity(item.severity),
                .message = message,
                .code = item.code,
                .spec_url = spec_url,
                .related = related,
                .tags = Diagnostics.tagsForCode(item.code),
                .data = data,
            };
        }

        // Project-level diagnostics (P0001–P0004) carry no author range;
        // the requested document is still where the editor sees them, at
        // 0:0, exactly as phase 03 published them.
        return .{
            .range = zeroRange(),
            .severity = lspSeverity(item.severity),
            .message = message,
            .code = item.code,
            .related = related,
        };
    }

    fn convertRelated(self: *ReportImpl, relations: []const Projection.Related) ![]const LspRelatedInfo {
        if (relations.len == 0) return &.{};
        var out: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer {
            for (out.items) |item| {
                if (item.uri.len > 0) self.gpa.free(item.uri);
                if (item.message.len > 0) self.gpa.free(item.message);
            }
            out.deinit(self.gpa);
        }

        for (relations) |relation| {
            const target: RelatedLocation = switch (relation.target) {
                .author => |author| blk: {
                    const doc = (try self.docInfo(author.origin)) orelse continue;
                    const range = doc.mapper.range(author.range.start, author.range.end) orelse continue;
                    break :blk .{ .uri = doc.uri, .range = range };
                },
                .project => |project| blk: {
                    const doc = (try self.projectDocInfo(project.program)) orelse continue;
                    const range = doc.mapper.range(project.range.start, project.range.end) orelse continue;
                    break :blk .{ .uri = doc.uri, .range = range };
                },
            };
            const uri = try self.gpa.dupe(u8, target.uri);
            errdefer self.gpa.free(uri);
            const message = try dupeOrEmpty(self.gpa, relation.message);
            errdefer if (message.len > 0) self.gpa.free(message);
            const item: LspRelatedInfo = .{
                .uri = uri,
                .range = target.range,
                .message = message,
            };
            out.append(self.gpa, item) catch |err| {
                self.gpa.free(uri);
                if (message.len > 0) self.gpa.free(message);
                return err;
            };
        }
        return out.toOwnedSlice(self.gpa);
    }

    fn convertData(self: *ReportImpl, item: Projection.DiagnosticOut) !WgslDiagnostic.QuickFixHint {
        if (item.data != .none) return Diagnostics.dupeQuickFixHint(self.gpa, item.data);
        const fix = item.fix orelse return .none;
        const doc = (try self.docInfo(fix.origin)) orelse return .none;
        const range = doc.mapper.range(fix.range.start, fix.range.end) orelse return .none;
        return .{ .lint_fix = .{
            .start_line = range.start.line,
            .start_character = range.start.character,
            .end_line = range.end.line,
            .end_character = range.end.character,
            .text = try dupeOrEmpty(self.gpa, fix.text),
        } };
    }

    fn docInfo(self: *ReportImpl, origin: Pngine.OriginKey) !?*OriginDoc {
        if (self.docs.getPtr(origin)) |doc| return doc;

        const path = self.inner.originPath(origin) orelse return null;
        const text = self.inner.originText(origin) orelse return null;
        const uri = if (containsOrigin(self.requested_parts, origin))
            try self.gpa.dupe(u8, self.requested_uri)
        else
            try pngine_path.pathToFileUri(self.gpa, path);
        errdefer self.gpa.free(uri);

        var mapper = try Handler.PositionMapper.init(self.gpa, text);
        errdefer mapper.deinit(self.gpa);

        const gop = try self.docs.getOrPut(self.gpa, origin);
        if (gop.found_existing) {
            mapper.deinit(self.gpa);
            self.gpa.free(uri);
            return gop.value_ptr;
        }
        gop.value_ptr.* = .{ .uri = uri, .mapper = mapper };
        return gop.value_ptr;
    }

    fn projectDocInfo(self: *ReportImpl, program_id: Pngine.Types.ProgramId) !?*ProjectDoc {
        if (self.project_docs.get(program_id)) |doc| return doc;

        const path = self.inner.projectPath(program_id) orelse return null;
        const text = self.inner.projectText(program_id) orelse return null;
        const uri = try pngine_path.pathToFileUri(self.gpa, path);
        errdefer self.gpa.free(uri);

        var mapper = try Handler.PositionMapper.init(self.gpa, text);
        errdefer mapper.deinit(self.gpa);

        const doc = try self.gpa.create(ProjectDoc);
        errdefer self.gpa.destroy(doc);
        doc.* = .{ .uri = uri, .mapper = mapper };
        try self.project_docs.put(self.gpa, program_id, doc);
        return doc;
    }
};

fn lspSeverity(severity: WgslDiagnostic.Severity) Handler.DiagnosticSeverity {
    return switch (severity) {
        .@"error" => .@"error",
        .warning => .warning,
        .hint => .hint,
        .note => .information,
        else => .information,
    };
}

fn zeroRange() Handler.Range {
    const zero: Handler.Position = .{ .line = 0, .character = 0 };
    return .{ .start = zero, .end = zero };
}

fn dupeOrEmpty(gpa: Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return gpa.dupe(u8, value);
}

fn freeRelatedSlice(gpa: Allocator, related: []const LspRelatedInfo) void {
    if (related.len == 0) return;
    for (related) |item| {
        if (item.uri.len > 0) gpa.free(item.uri);
        if (item.message.len > 0) gpa.free(item.message);
    }
    gpa.free(related);
}

fn buildSpecUrl(gpa: Allocator, code: []const u8, spec_ref: []const u8) ![]const u8 {
    if (code.len == 0 or spec_ref.len == 0) return "";
    const base = Diagnostics.wgsl_spec_base;
    const url = try gpa.alloc(u8, base.len + spec_ref.len);
    @memcpy(url[0..base.len], base);
    @memcpy(url[base.len..], spec_ref);
    return url;
}
