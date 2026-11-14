//! Composed diagnostic projection for pngine shader projects
//! (pngine-shaders phase 03, Tasks 2–3).
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
//! Task 3 adds multi-root semantics on top of Task 2's projection:
//!
//! - Validator entries from every containing shader-module root are unioned
//!   and deduplicated by `(mapped author range, code, original message)` in
//!   first-seen order. A group that appeared in more than one root carries
//!   one related entry per failing root (its `.sjon` root form), in root
//!   order.
//! - `E0100` is rewritten only on the composed path: the original validator
//!   message gains ` — declared nowhere in pngine module '<root>'` and always
//!   carries the root form as related information. The standalone
//!   `validateDocument*` path never enters this module, so its wording is
//!   untouched.
//! - Assembly failures become `P0002`, an unfilled `:requires` hole becomes
//!   `P0003`, and a pass-only context becomes `P0004`. A known fragment with
//!   no usable shader-module root additionally gets local parse diagnostics
//!   and one `P0001`, but never standalone semantic diagnostics.
//!
//! Task 4 adds whole-unit lint semantics on top of the same projection:
//!
//! - Configured packs run once per containing root against the cached
//!   `RootAnalysis`, using the standalone path's extends/override
//!   construction. `include_minify_lints` adds `@wgslender/minify`; the
//!   cheap path keeps running only the general packs, exactly as the
//!   single-document split does.
//! - `W0001`/`W0002`/`W0003` are liveness findings: they are emitted only
//!   when every lint-capable root that contains the requested file also
//!   produced them. A declaration used by one root is unused nowhere, so
//!   the report drops the finding rather than choosing a root.
//! - Every other lint finding is unioned and deduplicated by mapped
//!   author range, code, and message — a style rule fires once per origin,
//!   not once per root.
//! - `M0500` is a whole-module size claim. It is disabled when more than
//!   one shader-module root contains the requested part; no root's byte
//!   count is a property of a shared fragment.
//! - A lint quick fix survives only when its whole edit range maps to the
//!   requested author file and every root offering that fix agrees on the
//!   replacement. Cross-part, inline-`code`, and conflicting fixes are
//!   withheld while the diagnostic itself remains.
//!
//! The projector reads only the Store's already-resolved author texts. It
//! never parses or rescans assembled text; all identity comes from the
//! phase-02 segments. Requirement holes are judged against the assembled
//! module's parsed `Ast.Decl` list, never by substring search.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");
const pngine_path = @import("pngine_path");
const Handler = @import("../Handler.zig");
const Diagnostics = Handler.Diagnostics;

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;
const WgslDiagnostic = wgslender.Diagnostic;
const LspDiagnostic = Handler.LspDiagnostic;
const LspRelatedInfo = Handler.LspRelatedInfo;
const MinifySettings = wgslender.MinifySettings;

const Allocator = std.mem.Allocator;
const Ast = wgslender.Ast;

/// `@wgslender/minify`'s estimator-backed module-size rule. It is the one
/// lint finding whose meaning is a property of the whole assembled module
/// rather than the author part it anchors on.
const code_minify_size = "M0500";
const id_minify_size = "minify/shader-exceeds-size-budget";

/// Options accepted by `Handler.validatePngineDocument`. `include_minify_lints`
/// mirrors the standalone cheap/full split: general packs always run when the
/// LSP lint setting is on, while the `@wgslender/minify` pack (and the
/// estimator-backed M-rules) only joins on the full path.
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
            try report.addIncomplete(if (shader_roots.items.len == 0)
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

/// Run the configured lint packs against one cached root analysis and
/// project every entry through the same `Report` the validator uses.
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
    eff_minify: MinifySettings.Effective,
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
        .id = id_minify_size,
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

/// One parsed `.sjon` document, used only to turn graph-error spans into
/// LSP locations. The Store keeps the parsed graph but not the document
/// text, so this is resolved lazily through the Store's provider — never
/// by opening a path here.
const ProjectDoc = struct {
    uri: []u8,
    text: []u8,
    mapper: Handler.PositionMapper,

    fn deinit(self: *ProjectDoc, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        gpa.free(self.text);
        gpa.free(self.uri);
    }
};

/// One deduplicated validator or lint finding. `roots` records every root
/// whose analysis produced it; root relations are materialised at `finish`
/// only for multi-root groups (and always for E0100).
const FindingKind = enum { validator, lint };

/// A lint rewrite projected into the requested document's coordinates.
/// Several roots may offer one for the same finding; `finish` keeps the
/// replacement only when they agree byte-for-byte.
const FixCandidate = struct {
    range: Handler.Range,
    /// Owned by the Report when non-empty; `""` is the shared empty slice.
    text: []const u8,
};

const Finding = struct {
    kind: FindingKind = .validator,
    range: Handler.Range,
    severity: Handler.DiagnosticSeverity,
    code: []const u8,
    message: []const u8,
    spec_url: []const u8,
    related: std.ArrayList(LspRelatedInfo) = .empty,
    data: WgslDiagnostic.QuickFixHint = .none,
    roots: std.ArrayList(Pngine.RootId) = .empty,
    /// Lint-only: every root's projected rewrite, in first-seen order.
    fix_candidates: std.ArrayList(FixCandidate) = .empty,
    /// Lint-only: a range had competing rewrites, so no fix is offered.
    fix_conflicted: bool = false,
    tags: []const Handler.DiagnosticTag = &.{},
    /// Lint-only: whole-unit policy refused this finding.
    suppressed: bool = false,

    fn deinit(self: *Finding, gpa: Allocator) void {
        if (self.message.len > 0) gpa.free(self.message);
        if (self.spec_url.len > 0) gpa.free(self.spec_url);
        freeRelatedList(gpa, &self.related);
        Handler.Diagnostics.freeQuickFixHint(gpa, self.data);
        freeFixCandidates(gpa, &self.fix_candidates);
        self.roots.deinit(gpa);
    }
};

fn freeFixCandidates(gpa: Allocator, list: *std.ArrayList(FixCandidate)) void {
    for (list.items) |candidate| {
        if (candidate.text.len > 0) gpa.free(candidate.text);
    }
    list.deinit(gpa);
    list.* = .empty;
}

fn appendFixCandidate(
    gpa: Allocator,
    list: *std.ArrayList(FixCandidate),
    candidate: ?FixCandidate,
) !void {
    const item = candidate orelse return;
    list.append(gpa, item) catch |err| {
        if (item.text.len > 0) gpa.free(item.text);
        return err;
    };
}

fn rangeEql(a: Handler.Range, b: Handler.Range) bool {
    return std.meta.eql(a, b);
}

/// The one rewrite a finding may offer: every root must agree on both the
/// range and the replacement text. A disagreement is a conflict, not a
/// vote.
fn selectedFix(finding: *const Finding) ?FixCandidate {
    if (finding.fix_candidates.items.len == 0) return null;
    const first = finding.fix_candidates.items[0];
    for (finding.fix_candidates.items[1..]) |candidate| {
        if (!rangeEql(candidate.range, first.range)) return null;
        if (!std.mem.eql(u8, candidate.text, first.text)) return null;
    }
    return first;
}

fn isLivenessCode(code: []const u8) bool {
    return std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_unused_vars) or
        std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_dead_code) or
        std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_unused_binding);
}

const ReportImpl = struct {
    gpa: Allocator,
    store: *Pngine.Store,
    requested_uri: []const u8,
    /// The PartIds whose `:file` names the requested document. Filtering
    /// on identity (not a re-derived path string) keeps symlink/URI
    /// spelling from deciding which report a diagnostic belongs to.
    requested_parts: []const Pngine.OriginKey,
    /// Distinct shader-module roots that reach the requested file. This is
    /// the denominator for liveness intersection and the ambiguity test
    /// for module-size findings.
    request_roots: []const Pngine.RootId,
    /// Request roots whose assembled module parsed, so the linter could
    /// actually judge liveness in that context.
    lint_roots: std.ArrayList(Pngine.RootId) = .empty,
    docs: std.AutoHashMapUnmanaged(Pngine.OriginKey, OriginDoc) = .empty,
    project_docs: std.AutoHashMapUnmanaged(Pngine.Types.ProgramId, *ProjectDoc) = .empty,
    findings: std.ArrayList(Finding) = .empty,
    /// Project diagnostics (P0002/P0003/P0004 and local parse output) are
    /// already in final LSP shape; they are appended in discovery order.
    project_diags: std.ArrayList(LspDiagnostic) = .empty,
    /// Set when at least one entry had no honest author primary range.
    dropped: bool = false,
    /// An explicit reason for `P0001`; at most one is emitted per report.
    incomplete_reason: ?[]const u8 = null,
    /// How many shader-module roots contain the requested file. A single
    /// root is the report's own context; two or more make even a
    /// one-root finding root-specific and worth naming explicitly.
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
            if (!containsPart(requested_parts.items, membership.part)) {
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
        return .{
            .gpa = gpa,
            .store = store,
            .requested_uri = requested_uri,
            .requested_parts = requested_parts.toOwnedSlice(gpa) catch &.{},
            .request_roots = request_roots.toOwnedSlice(gpa) catch &.{},
        };
    }

    pub fn deinit(self: *ReportImpl) void {
        for (self.findings.items) |*finding| finding.deinit(self.gpa);
        self.findings.deinit(self.gpa);
        self.lint_roots.deinit(self.gpa);
        if (self.request_roots.len > 0) self.gpa.free(@constCast(self.request_roots));
        for (self.project_diags.items) |diag| Handler.Diagnostics.freeSingleDiagnostic(self.gpa, diag);
        self.project_diags.deinit(self.gpa);
        var it = self.docs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        var project_it = self.project_docs.iterator();
        while (project_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.project_docs.deinit(self.gpa);
        if (self.requested_parts.len > 0) self.gpa.free(@constCast(self.requested_parts));
    }

    /// Task 2's single-root entry point, retained for the projection tests.
    pub fn add(self: *ReportImpl, assembled: *const Pngine.Assembled, entry: *const WgslDiagnostic.Entry) !void {
        try self.addInternal(assembled, null, entry, .validator);
    }

    /// Composed entry point: records which root produced the finding so a
    /// multi-root dedupe can name every failing root.
    pub fn addFromRoot(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        root: Pngine.RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.addInternal(assembled, root, entry, .validator);
    }

    /// Lint entry point: same projection and root attachment as validator
    /// entries, plus the whole-unit liveness and fix-conflict policies.
    pub fn addLintFromRoot(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        root: Pngine.RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.addInternal(assembled, root, entry, .lint);
    }

    /// Number of distinct shader-module roots that reach the requested
    /// file. Zero for a synthetic report with no memberships.
    pub fn requestRootCount(self: *const ReportImpl) usize {
        return self.request_roots.len;
    }

    /// Record that `root` assembled into a module the linter could judge.
    /// Only request roots participate in liveness intersection.
    pub fn noteRootAnalyzed(self: *ReportImpl, root: Pngine.RootId, lint_capable: bool) !void {
        if (!lint_capable) return;
        if (!containsRoot(self.request_roots, root)) return;
        try appendRoot(self.gpa, &self.lint_roots, root);
    }

    pub fn finish(self: *ReportImpl) ![]LspDiagnostic {
        var out: std.ArrayList(LspDiagnostic) = .empty;
        errdefer {
            for (out.items) |diag| Handler.Diagnostics.freeSingleDiagnostic(self.gpa, diag);
            out.deinit(self.gpa);
        }

        // Project-level diagnostics keep their discovery order.
        try out.appendSlice(self.gpa, self.project_diags.items);
        self.project_diags.clearRetainingCapacity();

        self.applyLintPolicy();
        self.dropSuppressedFindings();
        self.resolveFixConflicts();

        for (self.findings.items) |*finding| {
            try self.finalizeLintFix(finding);
            try self.finalizeFinding(finding);

            const related_slice: []const LspRelatedInfo = if (finding.related.items.len > 0)
                try finding.related.toOwnedSlice(self.gpa)
            else
                &.{};
            errdefer freeRelated(self.gpa, related_slice);

            try out.append(self.gpa, .{
                .range = finding.range,
                .severity = finding.severity,
                .message = finding.message,
                .code = finding.code,
                .spec_url = finding.spec_url,
                .related = related_slice,
                .tags = finding.tags,
                .data = finding.data,
            });

            // Ownership moved to `out`; clear every owned field so a later
            // OOM path cannot free the same bytes twice.
            finding.message = "";
            finding.spec_url = "";
            finding.data = .none;
            finding.tags = &.{};
            freeFixCandidates(self.gpa, &finding.fix_candidates);
            finding.roots.deinit(self.gpa);
            finding.roots = .empty;
        }
        self.findings.clearRetainingCapacity();

        if (self.dropped or self.incomplete_reason != null) {
            const incomplete = try self.incompleteDiagnostic();
            try out.append(self.gpa, incomplete);
        }

        return out.toOwnedSlice(self.gpa);
    }

    /// Whole-unit policy. Liveness findings must hold in every root the
    /// linter could judge; the module-size rule needs one root context.
    fn applyLintPolicy(self: *ReportImpl) void {
        for (self.findings.items) |*finding| {
            if (finding.kind != .lint) continue;
            if (isLivenessCode(finding.code)) {
                if (!self.lintHoldsEverywhere(finding)) finding.suppressed = true;
            } else if (std.mem.eql(u8, finding.code, code_minify_size)) {
                if (self.request_roots.len > 1) finding.suppressed = true;
            }
        }
    }

    /// Remove refused findings before the first fallible emission step, so
    /// a later OOM can neither emit one nor free its storage twice.
    fn dropSuppressedFindings(self: *ReportImpl) void {
        var kept: usize = 0;
        for (self.findings.items) |finding| {
            if (finding.suppressed) {
                var doomed = finding;
                doomed.deinit(self.gpa);
                continue;
            }
            self.findings.items[kept] = finding;
            kept += 1;
        }
        self.findings.shrinkRetainingCapacity(kept);
    }

    fn lintHoldsEverywhere(self: *const ReportImpl, finding: *const Finding) bool {
        // A synthetic Report used by projection tests never records an
        // analyzed root; there is nothing to disprove the finding.
        if (self.lint_roots.items.len == 0) return true;
        for (self.lint_roots.items) |root| {
            if (!containsRoot(finding.roots.items, root)) return false;
        }
        return true;
    }

    /// Two roots may offer different rewrites for the same author range.
    /// Neither may be applied blindly; drop both fixes and keep the
    /// diagnostics. Every candidate participates, including one belonging
    /// to a finding whose own roots already disagree, so an internally
    /// conflicted finding cannot lend credibility to a different text.
    fn resolveFixConflicts(self: *ReportImpl) void {
        for (self.findings.items, 0..) |*finding, index| {
            if (finding.kind != .lint) continue;
            for (finding.fix_candidates.items) |mine| {
                for (self.findings.items[index + 1 ..]) |*other| {
                    if (other.kind != .lint) continue;
                    for (other.fix_candidates.items) |theirs| {
                        if (!rangeEql(mine.range, theirs.range)) continue;
                        if (std.mem.eql(u8, mine.text, theirs.text)) continue;
                        finding.fix_conflicted = true;
                        other.fix_conflicted = true;
                    }
                }
            }
        }
    }

    fn finalizeLintFix(self: *ReportImpl, finding: *Finding) !void {
        if (finding.kind != .lint or finding.fix_conflicted) return;
        // A rule-supplied payload (`unused_symbol`) drives its own quick
        // fix; never replace it with a generic rewrite.
        if (finding.data != .none) return;
        const candidate = selectedFix(finding) orelse return;
        finding.data = .{ .lint_fix = .{
            .start_line = candidate.range.start.line,
            .start_character = candidate.range.start.character,
            .end_line = candidate.range.end.line,
            .end_character = candidate.range.end.character,
            .text = try dupeOrEmpty(self.gpa, candidate.text),
        } };
    }

    fn addInternal(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        root: ?Pngine.RootId,
        entry: *const WgslDiagnostic.Entry,
        kind: FindingKind,
    ) !void {
        const mapped = assembled.toOrigin(.{
            .start = entry.range.start.offset,
            .end = entry.range.end.offset,
        }) orelse {
            self.dropped = true;
            return;
        };

        const doc = (try self.docFor(mapped.origin)) orelse {
            // An inline `:code` part has author text but no URI until phase
            // 04 introduces the virtual document. No honest primary range
            // exists for an editor in this phase.
            self.dropped = true;
            return;
        };
        if (!self.isRequested(mapped.origin)) return;
        const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse {
            self.dropped = true;
            return;
        };

        const message = try dupeOrEmpty(self.gpa, entry.message);
        errdefer if (message.len > 0) self.gpa.free(message);

        if (self.findFinding(range, entry.code, message, kind)) |finding| {
            if (root) |id| try appendRoot(self.gpa, &finding.roots, id);
            if (kind == .lint) if (entry.fix) |fix| {
                const candidate = try self.projectFixCandidate(assembled, fix);
                try appendFixCandidate(self.gpa, &finding.fix_candidates, candidate);
            };
            if (message.len > 0) self.gpa.free(message);
            return;
        }

        var related = try self.projectRelated(assembled, entry);
        errdefer freeRelatedList(self.gpa, &related);

        const spec_url = try buildSpecUrl(self.gpa, entry);
        errdefer if (spec_url.len > 0) self.gpa.free(spec_url);

        const data = if (kind == .lint) blk: {
            break :blk switch (entry.data) {
                // A rule-emitted `.lint_fix` payload without byte ranges
                // cannot be verified against the assembled unit.
                .lint_fix => WgslDiagnostic.QuickFixHint.none,
                else => Handler.Diagnostics.dupeQuickFixHint(self.gpa, entry.data),
            };
        } else try self.projectData(assembled, entry);
        errdefer Handler.Diagnostics.freeQuickFixHint(self.gpa, data);

        var fix_candidates: std.ArrayList(FixCandidate) = .empty;
        errdefer freeFixCandidates(self.gpa, &fix_candidates);
        if (kind == .lint) if (entry.fix) |fix| {
            const candidate = try self.projectFixCandidate(assembled, fix);
            try appendFixCandidate(self.gpa, &fix_candidates, candidate);
        };

        var roots: std.ArrayList(Pngine.RootId) = .empty;
        errdefer roots.deinit(self.gpa);
        if (root) |id| try roots.append(self.gpa, id);

        try self.findings.append(self.gpa, .{
            .kind = kind,
            .range = range,
            .severity = switch (entry.severity) {
                .@"error" => .@"error",
                .warning => .warning,
                .hint => .hint,
                .note => .information,
                else => .information,
            },
            .code = entry.code,
            .message = message,
            .spec_url = spec_url,
            .related = related,
            .data = data,
            .roots = roots,
            .fix_candidates = fix_candidates,
            .tags = if (kind == .lint) Diagnostics.tagsForCode(entry.code) else &.{},
        });
    }

    fn findFinding(
        self: *ReportImpl,
        range: Handler.Range,
        code: []const u8,
        message: []const u8,
        kind: FindingKind,
    ) ?*Finding {
        for (self.findings.items) |*finding| {
            if (finding.kind != kind) continue;
            if (!std.meta.eql(finding.range, range)) continue;
            if (!std.mem.eql(u8, finding.code, code)) continue;
            if (!std.mem.eql(u8, finding.message, message)) continue;
            return finding;
        }
        return null;
    }

    /// Materialise root relations and the E0100 composed wording. This is
    /// the only place the standalone validator message is extended; the
    /// standalone `validateDocument*` pipeline never constructs a Report.
    fn finalizeFinding(self: *ReportImpl, finding: *Finding) !void {
        const is_unresolved = std.mem.eql(u8, finding.code, WgslDiagnostic.Code.undefined_symbol);

        if (is_unresolved and finding.roots.items.len > 0) {
            const root_name = try self.rootName(finding.roots.items[0]);
            const rewritten = try std.fmt.allocPrint(
                self.gpa,
                "{s} — declared nowhere in pngine module '{s}'",
                .{ finding.message, root_name orelse "?" },
            );
            if (finding.message.len > 0) self.gpa.free(finding.message);
            finding.message = rewritten;
        }

        // A single-root ordinary finding already has its root context from
        // the report itself. Multi-root groups must name every root; E0100
        // always links the controlling `.sjon` form, and a root-specific
        // finding in a file that several roots contain names the one root
        // that actually failed.
        const name_roots = finding.roots.items.len > 1 or
            is_unresolved or
            (self.semantic_root_count > 1 and finding.roots.items.len > 0);
        if (!name_roots) return;

        for (finding.roots.items) |root| {
            try appendRelated(self.gpa, &finding.related, try self.rootRelated(root));
        }
    }

    fn incompleteDiagnostic(self: *ReportImpl) !LspDiagnostic {
        const reason = self.incomplete_reason orelse
            "a diagnostic could not be projected to an author file";
        return .{
            .range = zeroRange(),
            .severity = .warning,
            .message = try std.fmt.allocPrint(
                self.gpa,
                "pngine project context is incomplete: {s}; only local syntax is reported",
                .{reason},
            ),
            .code = WgslDiagnostic.Code.pngine_context_incomplete,
        };
    }

    pub fn addIncomplete(self: *ReportImpl, reason: []const u8) !void {
        if (self.incomplete_reason == null) self.incomplete_reason = reason;
    }

    /// Parse only the requested author text, never the validator: a
    /// fragment with no usable module must not report unresolved sibling
    /// identifiers as if they were local syntax errors.
    pub fn addLocalSyntax(self: *ReportImpl) !void {
        for (self.requested_parts) |part| {
            var text = self.store.textForPart(part) catch |err| switch (err) {
                error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => continue,
                else => return err,
            };
            defer text.deinit(self.gpa);
            const diags = try localSyntaxDiagnostics(self.gpa, text.text);
            try self.addOwnedDiagnostics(diags);
            return;
        }
    }

    fn addOwnedDiagnostics(self: *ReportImpl, diags: []LspDiagnostic) !void {
        var index: usize = 0;
        while (index < diags.len) : (index += 1) {
            self.project_diags.append(self.gpa, diags[index]) catch |err| {
                for (diags[index..]) |diag| Handler.Diagnostics.freeSingleDiagnostic(self.gpa, diag);
                self.gpa.free(diags);
                return err;
            };
        }
        self.gpa.free(diags);
    }

    /// `ImportCycle` / `UnknownFragment` / `TooDeep` arrive as bare errors
    /// from `analyzeRoot`. The Store drops the `Assemble.Failure` payload,
    /// so recompute the same bounded walk here (it never touches sources)
    /// and, for `MissingSource`, identify the first reached part whose text
    /// the Store cannot resolve.
    pub fn addAssemblyFailure(self: *ReportImpl, root: Pngine.RootId, err: anyerror) !void {
        const program = self.store.program(root.program) orelse {
            const message = try std.fmt.allocPrint(
                self.gpa,
                "pngine module '<unknown>' cannot be assembled: {s}",
                .{@errorName(err)},
            );
            errdefer self.gpa.free(message);
            try self.project_diags.append(self.gpa, .{
                .range = zeroRange(),
                .severity = .@"error",
                .message = message,
                .code = WgslDiagnostic.Code.pngine_module_unassemblable,
            });
            return;
        };

        const root_part: ?*const Pngine.Types.Part = if (root.index < program.parts.len)
            &program.parts[root.index]
        else
            null;
        const root_name: []const u8 = if (root_part) |part| part.name else "?";

        var failure: Pngine.Assemble.Failure = .{ .root = root };
        var order: []u32 = &.{};
        const order_result = Pngine.Assemble.collectOrderWithLimits(self.gpa, program, root, .{}, &failure);
        if (order_result) |value| {
            order = value;
        } else |_| {}
        defer if (order.len > 0) self.gpa.free(order);

        var related: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer freeRelatedList(self.gpa, &related);

        var detail: ?[]u8 = null;
        defer if (detail) |owned| self.gpa.free(owned);
        if (err == error.ImportCycle) {
            const path = try joinCyclePath(self.gpa, failure.cycle.slice());
            defer self.gpa.free(path);

            detail = try std.fmt.allocPrint(self.gpa, "import cycle '{s}'", .{path});
            try appendRelated(self.gpa, &related, try self.rootRelated(root));
            for (failure.cycle.slice()) |name| {
                const part_index = program.findFragment(name) orelse continue;
                const part = &program.parts[part_index];
                try appendRelated(
                    self.gpa,
                    &related,
                    try self.partRelated(
                        root.program,
                        part_index,
                        part.name_span,
                        "import cycle '{s}'",
                        .{path},
                    ),
                );
            }
        } else if (err == error.UnknownFragment) {
            const at_index: u32 = if (failure.at) |at| at.index else root.index;
            const at_name: []const u8 = if (at_index < program.parts.len)
                program.parts[at_index].name
            else
                root_name;
            detail = try std.fmt.allocPrint(
                self.gpa,
                "unknown import '{s}' in fragment '{s}'",
                .{ failure.unknown, at_name },
            );
            try appendRelated(self.gpa, &related, try self.rootRelated(root));

            if (at_index < program.parts.len) {
                const part = &program.parts[at_index];
                var edge = part.form_span;
                for (part.imports) |import_ref| {
                    if (std.mem.eql(u8, import_ref.name, failure.unknown)) {
                        edge = import_ref.span;
                        break;
                    }
                }
                try appendRelated(
                    self.gpa,
                    &related,
                    try self.partRelated(
                        root.program,
                        at_index,
                        edge,
                        "unknown import '{s}'",
                        .{failure.unknown},
                    ),
                );
            }
        } else if (err == error.MissingSource) {
            const missing_index = try self.findMissingSource(root, order);
            const part_index = missing_index orelse root.index;
            const part: ?*const Pngine.Types.Part = if (part_index < program.parts.len)
                &program.parts[part_index]
            else
                root_part;
            const part_name: []const u8 = if (part) |value| value.name else "?";
            const file_path: []const u8 = if (part) |value| switch (value.origin) {
                .file => |source| source.path,
                .inline_code => "",
            } else "";

            detail = if (file_path.len > 0)
                try std.fmt.allocPrint(
                    self.gpa,
                    "missing source for part '{s}' (file '{s}')",
                    .{ part_name, file_path },
                )
            else
                try std.fmt.allocPrint(
                    self.gpa,
                    "missing source for part '{s}'",
                    .{part_name},
                );

            try appendRelated(self.gpa, &related, try self.rootRelated(root));
            if (part) |value| {
                const span = switch (value.origin) {
                    .file => |source| source.span,
                    .inline_code => value.name_span,
                };
                try appendRelated(
                    self.gpa,
                    &related,
                    try self.partRelated(
                        root.program,
                        part_index,
                        span,
                        "missing source '{s}'",
                        .{if (file_path.len > 0) file_path else part_name},
                    ),
                );
            }
        } else if (err == error.TooDeep) {
            const at_index: u32 = if (failure.at) |at| at.index else root.index;
            const at_name: []const u8 = if (at_index < program.parts.len)
                program.parts[at_index].name
            else
                root_name;
            detail = try std.fmt.allocPrint(
                self.gpa,
                "import bound exceeded at part '{s}'",
                .{at_name},
            );
            try appendRelated(self.gpa, &related, try self.rootRelated(root));
            if (at_index < program.parts.len) {
                try appendRelated(
                    self.gpa,
                    &related,
                    try self.partRelated(
                        root.program,
                        at_index,
                        program.parts[at_index].form_span,
                        "import bound exceeded at part '{s}'",
                        .{at_name},
                    ),
                );
            }
        } else {
            detail = try std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)});
            try appendRelated(self.gpa, &related, try self.rootRelated(root));
        }

        const message = try std.fmt.allocPrint(
            self.gpa,
            "pngine module '{s}' cannot be assembled: {s}",
            .{ root_name, detail.? },
        );
        errdefer self.gpa.free(message);

        const related_slice: []const LspRelatedInfo = if (related.items.len > 0)
            try related.toOwnedSlice(self.gpa)
        else
            &.{};
        errdefer freeRelated(self.gpa, related_slice);

        try self.project_diags.append(self.gpa, .{
            .range = zeroRange(),
            .severity = .@"error",
            .message = message,
            .code = WgslDiagnostic.Code.pngine_module_unassemblable,
            .related = related_slice,
        });
    }

    fn findMissingSource(self: *ReportImpl, root: Pngine.RootId, order: []const u32) !?u32 {
        for (order) |part_index| {
            const id: Pngine.OriginKey = .{ .program = root.program, .index = part_index };
            if (try self.partTextMissing(id)) return part_index;
        }
        const root_id: Pngine.OriginKey = .{ .program = root.program, .index = root.index };
        if (try self.partTextMissing(root_id)) return root.index;
        return null;
    }

    fn partTextMissing(self: *ReportImpl, id: Pngine.OriginKey) !bool {
        var text = self.store.textForPart(id) catch |err| switch (err) {
            error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => return true,
            else => return err,
        };
        text.deinit(self.gpa);
        return false;
    }

    pub fn addPassUnsupported(self: *ReportImpl, root: Pngine.RootId) !void {
        const program = self.store.program(root.program) orelse return;
        if (root.index >= program.parts.len) return;
        const part = &program.parts[root.index];

        const message = try std.fmt.allocPrint(
            self.gpa,
            "pngine pass '{s}' requires generated bindings; semantic validation is unavailable for this context",
            .{part.name},
        );
        errdefer self.gpa.free(message);

        var related: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer freeRelatedList(self.gpa, &related);
        try appendRelated(self.gpa, &related, try self.rootRelated(root));

        const related_slice: []const LspRelatedInfo = if (related.items.len > 0)
            try related.toOwnedSlice(self.gpa)
        else
            &.{};
        errdefer freeRelated(self.gpa, related_slice);

        try self.project_diags.append(self.gpa, .{
            .range = zeroRange(),
            .severity = .warning,
            .message = message,
            .code = WgslDiagnostic.Code.pngine_pass_unsupported,
            .related = related_slice,
        });
    }

    /// Check every reached part's `:requires` against the assembled module's
    /// parsed top-level declarations. Only the requiring part's own report
    /// receives the primary P0003; the `.sjon` requirement and root form are
    /// related information.
    pub fn checkRequirements(
        self: *ReportImpl,
        root: Pngine.RootId,
        module: ?*Ast.Module,
    ) !void {
        const program = self.store.program(root.program) orelse return;
        const order = Pngine.Assemble.collectOrderWithLimits(self.gpa, program, root, .{}, null) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer if (order.len > 0) self.gpa.free(order);

        try self.checkPartRequirements(root, program, root.index, module);
        for (order) |part_index| {
            try self.checkPartRequirements(root, program, part_index, module);
        }
    }

    fn checkPartRequirements(
        self: *ReportImpl,
        root: Pngine.RootId,
        program: *const Pngine.Types.Program,
        part_index: u32,
        module: ?*Ast.Module,
    ) !void {
        if (part_index >= program.parts.len) return;
        const part = &program.parts[part_index];
        if (part.requires.len == 0) return;

        const id: Pngine.OriginKey = .{ .program = root.program, .index = part_index };
        if (!self.isRequested(id)) return;

        const parsed = module orelse return;
        for (part.requires) |requirement| {
            if (moduleDeclares(parsed, requirement.name)) continue;
            try self.addMissingRequirement(root, program, part_index, requirement);
        }
    }

    fn addMissingRequirement(
        self: *ReportImpl,
        root: Pngine.RootId,
        program: *const Pngine.Types.Program,
        part_index: u32,
        requirement: Pngine.Types.Requirement,
    ) !void {
        const part = &program.parts[part_index];
        const root_part = if (root.index < program.parts.len) &program.parts[root.index] else part;

        const message = try std.fmt.allocPrint(
            self.gpa,
            "fragment '{s}' requires '{s}', declared nowhere in pngine module '{s}'",
            .{ part.name, requirement.name, root_part.name },
        );
        errdefer self.gpa.free(message);

        var related: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer freeRelatedList(self.gpa, &related);
        try appendRelated(
            self.gpa,
            &related,
            try self.partRelated(
                root.program,
                part_index,
                requirement.span,
                "requirement '{s}'",
                .{requirement.name},
            ),
        );
        try appendRelated(self.gpa, &related, try self.rootRelated(root));

        const related_slice: []const LspRelatedInfo = if (related.items.len > 0)
            try related.toOwnedSlice(self.gpa)
        else
            &.{};
        errdefer freeRelated(self.gpa, related_slice);

        try self.project_diags.append(self.gpa, .{
            .range = zeroRange(),
            .severity = .@"error",
            .message = message,
            .code = WgslDiagnostic.Code.pngine_missing_requirement,
            .related = related_slice,
        });
    }

    fn projectRelated(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        entry: *const WgslDiagnostic.Entry,
    ) !std.ArrayList(LspRelatedInfo) {
        var list: std.ArrayList(LspRelatedInfo) = .empty;
        errdefer freeRelatedList(self.gpa, &list);
        if (entry.related.len == 0) return list;

        for (entry.related) |rel| {
            const mapped = assembled.toOrigin(.{
                .start = rel.range.start.offset,
                .end = rel.range.end.offset,
            }) orelse continue;
            const doc = (try self.docFor(mapped.origin)) orelse continue;
            const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse continue;

            const message = try dupeOrEmpty(self.gpa, rel.message);
            const uri = self.gpa.dupe(u8, doc.uri) catch |err| {
                if (message.len > 0) self.gpa.free(message);
                return err;
            };
            // `appendRelated` owns both strings and frees them on failure.
            try appendRelated(self.gpa, &list, .{
                .uri = uri,
                .range = range,
                .message = message,
            });
        }
        return list;
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

    /// Project a lint fix into author coordinates without committing to it.
    /// The caller collects one candidate per root and only emits a
    /// `.lint_fix` after every candidate agrees. A range that leaves the
    /// requested file, enters inline `:code`, or crosses a part boundary
    /// has no safe author representation and yields null.
    fn projectFixCandidate(
        self: *ReportImpl,
        assembled: *const Pngine.Assembled,
        fix: *const WgslDiagnostic.Fix,
    ) !?FixCandidate {
        const mapped = assembled.toOrigin(.{
            .start = fix.range.start.offset,
            .end = fix.range.end.offset,
        }) orelse return null;
        if (!self.isRequested(mapped.origin)) return null;
        const doc = (try self.docFor(mapped.origin)) orelse return null;
        const range = doc.mapper.range(mapped.range.start, mapped.range.end) orelse return null;
        return .{ .range = range, .text = try dupeOrEmpty(self.gpa, fix.text) };
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

    fn rootName(self: *ReportImpl, root: Pngine.RootId) !?[]const u8 {
        const program = self.store.program(root.program) orelse return null;
        if (root.index >= program.parts.len) return null;
        return program.parts[root.index].name;
    }

    fn rootRelated(self: *ReportImpl, root: Pngine.RootId) !?LspRelatedInfo {
        const program = self.store.program(root.program) orelse return null;
        if (root.index >= program.parts.len) return null;
        const part = &program.parts[root.index];
        return self.partRelated(
            root.program,
            root.index,
            part.form_span,
            "root '{s}'",
            .{part.name},
        );
    }

    fn partRelated(
        self: *ReportImpl,
        program_id: Pngine.Types.ProgramId,
        part_index: u32,
        span: Pngine.Types.Span,
        comptime format: []const u8,
        args: anytype,
    ) !?LspRelatedInfo {
        const program = self.store.program(program_id) orelse return null;
        if (part_index >= program.parts.len) return null;
        const doc = (try self.projectDoc(program_id)) orelse return null;
        const range = doc.mapper.range(span.start, span.end) orelse return null;

        const uri = try self.gpa.dupe(u8, doc.uri);
        errdefer self.gpa.free(uri);
        const message = try std.fmt.allocPrint(self.gpa, format, args);
        return .{ .uri = uri, .range = range, .message = message };
    }

    /// Lazily read one `.sjon` document through the Store's provider for
    /// related-location ranges. The Store parses and owns the graph but
    /// does not retain the document text.
    fn projectDoc(self: *ReportImpl, program_id: Pngine.Types.ProgramId) !?*ProjectDoc {
        if (self.project_docs.get(program_id)) |doc| return doc;

        const program = self.store.program(program_id) orelse return null;
        const uri = pngine_path.pathToFileUri(self.gpa, program.document_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        errdefer self.gpa.free(uri);

        const text = self.store.provider.readText(self.gpa, program.document_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        errdefer self.gpa.free(text);

        // The graph's spans index the exact text that produced it. If the
        // document changed after the Store parsed it, a freshly read text
        // could turn a related range into a lie; omit the range instead.
        const hash = Pngine.Types.contentHash(text);
        if (!std.mem.eql(u8, &hash, &program.document_hash)) return null;

        var mapper = try Handler.PositionMapper.init(self.gpa, text);
        errdefer mapper.deinit(self.gpa);

        const doc = try self.gpa.create(ProjectDoc);
        errdefer self.gpa.destroy(doc);
        doc.* = .{ .uri = uri, .text = text, .mapper = mapper };
        try self.project_docs.put(self.gpa, program_id, doc);
        return doc;
    }
};

fn moduleDeclares(module: *const Ast.Module, name: []const u8) bool {
    for (module.declarations.items) |decl| {
        const symbol_index = decl.nameRef();
        if (!symbol_index.isValid()) continue;
        const index = symbol_index.index();
        if (index >= module.symbols.items.len) continue;
        const symbol = module.symbols.items[index];
        if (symbol.flags.is_retired) continue;
        if (std.mem.eql(u8, symbol.original_name, name)) return true;
    }
    return false;
}

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

fn localSyntaxDiagnostics(gpa: Allocator, source: []const u8) ![]LspDiagnostic {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_z = try alloc.dupeZ(u8, source);
    const tokens = try wgslender.Lexer.tokenize(alloc, source_z);
    var parser = try wgslender.Parser.init(alloc, source_z, tokens);
    _ = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };

    var diagnostics = try wgslender.Diagnostic.init(alloc, source_z);
    wgslender.Parser.mergeErrorsInto(parser.errors.items, &diagnostics, alloc);
    const entries = diagnostics.diagnostics.items;

    const out = try gpa.alloc(LspDiagnostic, entries.len);
    errdefer gpa.free(out);
    var mapper = try Handler.PositionMapper.init(gpa, source);
    defer mapper.deinit(gpa);
    for (entries, 0..) |entry, index| {
        out[index] = Handler.Diagnostics.convertDiagnostic(gpa, &mapper, &entry);
    }
    return out;
}

fn joinCyclePath(gpa: Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(gpa, " -> ");
        try out.appendSlice(gpa, name);
    }
    return out.toOwnedSlice(gpa);
}

fn zeroRange() Handler.Range {
    const zero: Handler.Position = .{ .line = 0, .character = 0 };
    return .{ .start = zero, .end = zero };
}

fn dupeOrEmpty(gpa: Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return gpa.dupe(u8, value);
}

fn appendRelated(
    gpa: Allocator,
    list: *std.ArrayList(LspRelatedInfo),
    relation: ?LspRelatedInfo,
) !void {
    const item = relation orelse return;
    list.append(gpa, item) catch |err| {
        freeRelatedItem(gpa, item);
        return err;
    };
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

fn freeRelatedList(gpa: Allocator, list: *std.ArrayList(LspRelatedInfo)) void {
    for (list.items) |item| freeRelatedItem(gpa, item);
    list.deinit(gpa);
    list.* = .empty;
}

fn buildSpecUrl(gpa: Allocator, entry: *const WgslDiagnostic.Entry) ![]const u8 {
    if (entry.code.len == 0 or entry.spec_ref.len == 0) return "";
    const base = Handler.Diagnostics.wgsl_spec_base;
    const url = try gpa.alloc(u8, base.len + entry.spec_ref.len);
    @memcpy(url[0..base.len], base);
    @memcpy(url[base.len..], entry.spec_ref);
    return url;
}
