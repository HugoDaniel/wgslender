//! Shared composed diagnostic projector for pngine shader projects.
//!
//! Phase 03 built the projection, multi-root merge, graph-error reporting,
//! and whole-unit lint policy into `lsp/handler/pngine_diagnostics.zig`. The
//! native CLI needs exactly the same semantics for `validate` and `lint`
//! over a pngine selection, so the engine lives here and both frontends
//! drive it. The LSP adapter converts the neutral author-byte results into
//! LSP positions/URIs; the CLI converts them into `file:line:col` text and
//! JSON entries.
//!
//! ## Rules preserved from phase 03
//!
//! - A primary entry is returned only when its assembled range maps to one
//!   honest author range. An entry with no honest author range (a cross-part
//!   range, a blanked directive, or an inline `:code` part with no file URI)
//!   is dropped and the report records one degradation. `finish` appends a
//!   single `P0001` for the whole report, never one per dropped entry.
//! - Related information is projected independently: each entry keeps its
//!   own origin and range. A relation that cannot be mapped is omitted rather
//!   than clamped to a different file.
//! - A textual fix survives only when the primary and the fix range both
//!   resolve into an allowed author origin. A cross-part fix is withheld.
//! - Validator entries from every added root are unioned and deduplicated by
//!   `(origin, mapped author range, code, original message)` in first-seen
//!   order. A group that appeared in more than one root carries one related
//!   entry per failing root (its `.sjon` root form), in root order.
//! - `E0100` gains ` — declared nowhere in pngine module '<root>'` and always
//!   carries the root form as related information.
//! - Assembly failures become `P0002`, an unfilled `:requires` hole becomes
//!   `P0003`, and a pass-only context becomes `P0004`.
//! - `W0001`/`W0002`/`W0003` are emitted only when every lint-capable root
//!   produced them. `M0500` is disabled when more than one root contains the
//!   request. Every other lint finding is unioned and deduplicated.
//! - A lint fix survives only when every root offering it agrees on the
//!   range and replacement.
//!
//! The projector reads only the Store's already-resolved author texts. It
//! never parses or rescans assembled text; all identity comes from the
//! phase-02 segments. Requirement holes are judged against the assembled
//! module's parsed `Ast.Decl` list, never by substring search.

const std = @import("std");
const Ast = @import("../Ast.zig");
const WgslDiagnostic = @import("../Diagnostic.zig");
const Assemble = @import("Assemble.zig");
const Path = @import("pngine_path");
const Store = @import("Store.zig").Store;
const types = @import("Types.zig");

const Allocator = std.mem.Allocator;

pub const RootId = Assemble.RootId;
pub const OriginKey = Assemble.OriginKey;

/// `@wgslender/minify`'s estimator-backed module-size rule. It is the one
/// lint finding whose meaning is a property of the whole assembled module
/// rather than the author part it anchors on.
const code_minify_size = "M0500";
const id_minify_size = "minify/shader-exceeds-size-budget";

/// A half-open author byte range (the phase-02 mapping type).
pub const ByteRange = Assemble.ByteRange;

/// A 1-based author/project position.
pub const Position = struct {
    line: u32,
    column: u32,
};

/// One projected relation's target. Author relations live in a WGSL part;
/// project relations live in the `.sjon` document (root forms, imports,
/// `:requires` spans).
pub const RelatedTarget = union(enum) {
    author: struct {
        origin: OriginKey,
        range: ByteRange,
    },
    project: struct {
        program: types.ProgramId,
        range: ByteRange,
    },
};

pub const Related = struct {
    target: RelatedTarget,
    message: []u8,
};

/// One retained fix, mapped to the author origin it rewrites.
pub const Fix = struct {
    origin: OriginKey,
    range: ByteRange,
    text: []u8,
};

/// A finished, neutral diagnostic. Strings are borrowed from the `Report`
/// that produced it and stay valid until that report is deinitialized.
pub const DiagnosticOut = struct {
    severity: WgslDiagnostic.Severity,
    code: []const u8,
    message: []const u8,
    spec_ref: []const u8 = "",
    source: []const u8 = "",
    /// Non-null only for a diagnostic projected onto an author file.
    origin: ?OriginKey = null,
    /// Author byte range when `origin` is non-null; zero otherwise.
    range: ByteRange = .{ .start = 0, .end = 0 },
    related: []const Related = &.{},
    fix: ?Fix = null,
    data: WgslDiagnostic.QuickFixHint = .none,
    roots: []const RootId = &.{},
    /// The program a project-level diagnostic belongs to, when known.
    program: ?types.ProgramId = null,
};

/// Owns the output slice; strings remain owned by `Report`.
pub const Result = struct {
    items: []DiagnosticOut,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self.items.len > 0) gpa.free(self.items);
        self.items = &.{};
    }
};

pub const Options = struct {
    /// Roots whose liveness intersection and multi-root policies apply.
    /// Callers pass the selected shader-module roots, not pass roots.
    roots: []const RootId,
    /// Author origins whose fixes may be retained. Null means "any origin"
    /// (the CLI reports every origin's fix; it applies only the input part's).
    fix_origins: ?[]const OriginKey = null,
};

const OriginDoc = struct {
    /// Absolute, lexically normalized author path. Empty for inline parts
    /// (which are not emitted as primaries and have no file URI).
    path: []u8,
    text: []u8,
    line_index: WgslDiagnostic.LineIndex,

    fn deinit(self: *OriginDoc, gpa: Allocator) void {
        self.line_index.deinit(gpa);
        gpa.free(self.text);
        gpa.free(self.path);
    }
};

/// One parsed `.sjon` document, used only to turn graph/root spans into
/// locations. The Store keeps the parsed graph but not the document text,
/// so this is resolved lazily through the Store's provider.
const ProjectDoc = struct {
    path: []u8,
    text: []u8,
    line_index: WgslDiagnostic.LineIndex,

    fn deinit(self: *ProjectDoc, gpa: Allocator) void {
        self.line_index.deinit(gpa);
        gpa.free(self.text);
        gpa.free(self.path);
    }
};

const FindingKind = enum { validator, lint };

const Finding = struct {
    kind: FindingKind = .validator,
    origin: OriginKey,
    range: ByteRange,
    severity: WgslDiagnostic.Severity,
    /// Diagnostic codes are static (`Diagnostic.Code` / rule metadata), so
    /// the projector borrows them instead of allocating an owned copy.
    code: []const u8,
    message: []u8,
    spec_ref: []u8,
    source: []u8,
    related: std.ArrayList(Related) = .empty,
    /// Bounded quick-fix hint. `.lint_fix` is reconstructed by the LSP
    /// adapter from `fix`, because that payload is expressed in LSP
    /// coordinates (UTF-16 columns) and the shared layer stores bytes.
    data: WgslDiagnostic.QuickFixHint = .none,
    fix: ?Fix = null,
    roots: std.ArrayList(RootId) = .empty,
    fix_conflicted: bool = false,
    suppressed: bool = false,

    fn deinit(self: *Finding, gpa: Allocator) void {
        gpa.free(self.message);
        gpa.free(self.spec_ref);
        gpa.free(self.source);
        freeRelatedList(gpa, &self.related);
        freeHint(gpa, self.data);
        if (self.fix) |fix| {
            if (fix.text.len > 0) gpa.free(fix.text);
        }
        self.roots.deinit(gpa);
    }
};

const ProjectDiagnostic = struct {
    severity: WgslDiagnostic.Severity,
    code: []const u8,
    message: []u8,
    program: ?types.ProgramId = null,
    related: std.ArrayList(Related) = .empty,

    fn deinit(self: *ProjectDiagnostic, gpa: Allocator) void {
        gpa.free(self.message);
        freeRelatedList(gpa, &self.related);
    }
};

pub const Report = struct {
    gpa: Allocator,
    store: *Store,
    roots: []RootId,
    fix_origins: ?[]OriginKey,
    docs: std.AutoHashMapUnmanaged(OriginKey, OriginDoc) = .empty,
    project_docs: std.AutoHashMapUnmanaged(types.ProgramId, *ProjectDoc) = .empty,
    findings: std.ArrayList(Finding) = .empty,
    /// Project diagnostics (P0002/P0003/P0004) are emitted before findings,
    /// in discovery order, exactly as the phase-03 LSP report did.
    project_diags: std.ArrayList(ProjectDiagnostic) = .empty,
    /// The single report-level P0001 is emitted after findings, exactly as
    /// phase 03 did. It owns its message here so `deinit` can free it.
    tail_diags: std.ArrayList(ProjectDiagnostic) = .empty,
    /// Roots whose assembled module parsed, so the linter could judge
    /// liveness in that context.
    lint_roots: std.ArrayList(RootId) = .empty,
    dropped: bool = false,
    incomplete_reason: ?[]const u8 = null,
    /// How many shader-module roots the caller selected. A single root is
    /// the report's own context; two or more make even a one-root finding
    /// root-specific and worth naming explicitly.
    semantic_root_count: usize = 0,

    pub fn init(gpa: Allocator, store: *Store, options: Options) !Report {
        const roots = try gpa.dupe(RootId, options.roots);
        errdefer gpa.free(roots);
        const fix_origins = if (options.fix_origins) |origins|
            try gpa.dupe(OriginKey, origins)
        else
            null;
        return .{
            .gpa = gpa,
            .store = store,
            .roots = roots,
            .fix_origins = fix_origins,
        };
    }

    pub fn deinit(self: *Report) void {
        for (self.findings.items) |*finding| finding.deinit(self.gpa);
        self.findings.deinit(self.gpa);
        for (self.project_diags.items) |*diag| diag.deinit(self.gpa);
        self.project_diags.deinit(self.gpa);
        for (self.tail_diags.items) |*diag| diag.deinit(self.gpa);
        self.tail_diags.deinit(self.gpa);
        self.lint_roots.deinit(self.gpa);
        var it = self.docs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        var project_it = self.project_docs.iterator();
        while (project_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.project_docs.deinit(self.gpa);
        if (self.roots.len > 0) self.gpa.free(self.roots);
        if (self.fix_origins) |origins| if (origins.len > 0) self.gpa.free(origins);
        self.* = undefined;
    }

    /// Number of selected shader-module roots. Zero for a synthetic report.
    pub fn requestRootCount(self: *const Report) usize {
        return self.roots.len;
    }

    /// Add one validator/lint entry without recording which root produced
    /// it. Kept for projection tests and single-root callers.
    pub fn add(self: *Report, assembled: *const Assemble.Assembled, entry: *const WgslDiagnostic.Entry) !void {
        try self.addInternal(assembled, null, entry, .validator);
    }

    pub fn addFromRoot(
        self: *Report,
        assembled: *const Assemble.Assembled,
        root: RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.addInternal(assembled, root, entry, .validator);
    }

    pub fn addLintFromRoot(
        self: *Report,
        assembled: *const Assemble.Assembled,
        root: RootId,
        entry: *const WgslDiagnostic.Entry,
    ) !void {
        try self.addInternal(assembled, root, entry, .lint);
    }

    /// Record that `root` assembled into a module the linter could judge.
    /// Only selected roots participate in liveness intersection.
    pub fn noteRootAnalyzed(self: *Report, root: RootId, lint_capable: bool) !void {
        if (!lint_capable) return;
        if (!containsRoot(self.roots, root)) return;
        try appendRoot(self.gpa, &self.lint_roots, root);
    }

    pub fn addIncomplete(self: *Report, reason: []const u8) void {
        if (self.incomplete_reason == null) self.incomplete_reason = reason;
    }

    // =====================================================================
    // Author/project location queries used by the frontends.
    // =====================================================================

    /// Absolute author path for an origin, or null for an inline part.
    pub fn originPath(self: *Report, origin: OriginKey) ?[]const u8 {
        const doc = self.docFor(origin) catch return null;
        return if (doc) |value| value.path else null;
    }

    /// Current author text for an origin.
    pub fn originText(self: *Report, origin: OriginKey) ?[]const u8 {
        const doc = self.docFor(origin) catch return null;
        return if (doc) |value| value.text else null;
    }

    /// 1-based line/column for an author byte offset.
    pub fn originPosition(self: *Report, origin: OriginKey, offset: u32) ?Position {
        const doc = self.docFor(origin) catch return null;
        const value = doc orelse return null;
        const lc = value.line_index.byteOffsetToLineColumn(offset);
        return .{ .line = lc.line + 1, .column = lc.col + 1 };
    }

    /// Path of the `.sjon` document that owns `program`.
    pub fn projectPath(self: *const Report, program: types.ProgramId) ?[]const u8 {
        const value = self.store.program(program) orelse return null;
        return value.document_path;
    }

    /// Current text of the `.sjon` document that owns `program`.
    pub fn projectText(self: *Report, program: types.ProgramId) ?[]const u8 {
        const doc = self.projectDoc(program) catch return null;
        return if (doc) |value| value.text else null;
    }

    /// 1-based line/column for a byte offset in the `.sjon` document.
    pub fn projectPosition(
        self: *Report,
        program: types.ProgramId,
        offset: u32,
    ) ?Position {
        const doc = self.projectDoc(program) catch return null;
        const value = doc orelse return null;
        const lc = value.line_index.byteOffsetToLineColumn(offset);
        return .{ .line = lc.line + 1, .column = lc.col + 1 };
    }

    /// Name of a root, for JSON `root` fields and human output.
    pub fn rootName(self: *const Report, root: RootId) ?[]const u8 {
        const program = self.store.program(root.program) orelse return null;
        if (root.index >= program.parts.len) return null;
        return program.parts[root.index].name;
    }

    // =====================================================================
    // Additive input
    // =====================================================================

    fn addInternal(
        self: *Report,
        assembled: *const Assemble.Assembled,
        root: ?RootId,
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

        // An inline `:code` part has author text but no file URI; the shared
        // layer treats it as unprojectable, matching phase-03's LSP rule.
        if ((try self.docFor(mapped.origin)) == null) {
            self.dropped = true;
            return;
        }

        const message = try self.gpa.dupe(u8, entry.message);
        errdefer self.gpa.free(message);

        if (self.findFinding(mapped.origin, mapped.range, entry.code, message, kind)) |finding| {
            if (root) |id| try appendRoot(self.gpa, &finding.roots, id);
            if (entry.fix) |fix| {
                if (try self.projectFix(assembled, fix)) |candidate| {
                    if (finding.fix) |existing| {
                        // Every root offering this finding must agree on the
                        // rewrite. A disagreement withholds the fix.
                        if (!sameOrigin(existing.origin, candidate.origin) or
                            !rangeEql(existing.range, candidate.range) or
                            !std.mem.eql(u8, existing.text, candidate.text))
                        {
                            finding.fix_conflicted = true;
                        }
                        if (candidate.text.len > 0) self.gpa.free(candidate.text);
                    } else {
                        finding.fix = candidate;
                    }
                }
            }
            self.gpa.free(message);
            return;
        }

        const code = entry.code;
        const spec_ref = try self.gpa.dupe(u8, entry.spec_ref);
        errdefer self.gpa.free(spec_ref);
        const source = try self.gpa.dupe(u8, entry.source);
        errdefer self.gpa.free(source);

        var related = try self.projectRelated(assembled, entry);
        errdefer freeRelatedList(self.gpa, &related);

        const data: WgslDiagnostic.QuickFixHint = switch (entry.data) {
            // A lint-supplied `.lint_fix` without byte ranges cannot be
            // verified against the assembled unit; withhold it.
            .lint_fix => .none,
            else => dupeHint(self.gpa, entry.data),
        };
        errdefer freeHint(self.gpa, data);

        const fix: ?Fix = if (entry.fix) |source_fix| try self.projectFix(assembled, source_fix) else null;
        errdefer if (fix) |owned| if (owned.text.len > 0) self.gpa.free(owned.text);

        var roots: std.ArrayList(RootId) = .empty;
        errdefer roots.deinit(self.gpa);
        if (root) |id| try roots.append(self.gpa, id);

        try self.findings.append(self.gpa, .{
            .kind = kind,
            .origin = mapped.origin,
            .range = mapped.range,
            .severity = entry.severity,
            .code = code,
            .message = message,
            .spec_ref = spec_ref,
            .source = source,
            .related = related,
            .data = data,
            .fix = fix,
            .roots = roots,
        });
    }

    fn findFinding(
        self: *Report,
        origin: OriginKey,
        range: ByteRange,
        code: []const u8,
        message: []const u8,
        kind: FindingKind,
    ) ?*Finding {
        for (self.findings.items) |*finding| {
            if (finding.kind != kind) continue;
            if (finding.origin.program != origin.program or finding.origin.index != origin.index) continue;
            if (!rangeEql(finding.range, range)) continue;
            if (!std.mem.eql(u8, finding.code, code)) continue;
            if (!std.mem.eql(u8, finding.message, message)) continue;
            return finding;
        }
        return null;
    }

    fn projectRelated(
        self: *Report,
        assembled: *const Assemble.Assembled,
        entry: *const WgslDiagnostic.Entry,
    ) !std.ArrayList(Related) {
        var list: std.ArrayList(Related) = .empty;
        errdefer freeRelatedList(self.gpa, &list);
        if (entry.related.len == 0) return list;

        for (entry.related) |rel| {
            const mapped = assembled.toOrigin(.{
                .start = rel.range.start.offset,
                .end = rel.range.end.offset,
            }) orelse continue;
            if ((try self.docFor(mapped.origin)) == null) continue;

            const message = try self.gpa.dupe(u8, rel.message);
            errdefer if (message.len > 0) self.gpa.free(message);
            try list.append(self.gpa, .{
                .target = .{ .author = .{ .origin = mapped.origin, .range = mapped.range } },
                .message = message,
            });
        }
        return list;
    }

    /// Convert a fix only when its whole range maps to one allowed author
    /// origin. A cross-part, inline, or disallowed edit yields null.
    fn projectFix(
        self: *Report,
        assembled: *const Assemble.Assembled,
        fix: *const WgslDiagnostic.Fix,
    ) !?Fix {
        const mapped = assembled.toOrigin(.{
            .start = fix.range.start.offset,
            .end = fix.range.end.offset,
        }) orelse return null;
        if ((try self.docFor(mapped.origin)) == null) return null;
        if (!self.fixAllowed(mapped.origin)) return null;
        return .{
            .origin = mapped.origin,
            .range = mapped.range,
            .text = try dupeOrEmpty(self.gpa, fix.text),
        };
    }

    fn fixAllowed(self: *const Report, origin: OriginKey) bool {
        const allowed = self.fix_origins orelse return true;
        for (allowed) |candidate| {
            if (candidate.program == origin.program and candidate.index == origin.index) return true;
        }
        return false;
    }

    // =====================================================================
    // Local syntax, assembly failures, requirements, pass contexts
    // =====================================================================

    /// Parse only one author text, never the validator: a fragment with no
    /// usable module must not report unresolved sibling identifiers as if
    /// they were local syntax errors. `only` names the candidate origins in
    /// order; the first readable one is parsed.
    pub fn addLocalSyntax(self: *Report, only: ?[]const OriginKey) !void {
        const candidates = only orelse &.{};
        for (candidates) |origin| {
            var text = self.store.textForPart(origin) catch |err| switch (err) {
                error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => continue,
                else => return err,
            };
            defer text.deinit(self.gpa);
            return self.addSyntaxEntries(origin, text.text);
        }
    }

    fn addSyntaxEntries(self: *Report, origin: OriginKey, source: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_z = try alloc.dupeZ(u8, source);
        const tokens = try @import("../Lexer.zig").tokenize(alloc, source_z);
        var parser = try @import("../Parser.zig").init(alloc, source_z, tokens);
        _ = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };

        var diagnostics = try WgslDiagnostic.init(alloc, source_z);
        @import("../Parser.zig").mergeErrorsInto(parser.errors.items, &diagnostics, alloc);

        for (diagnostics.diagnostics.items) |*entry| {
            const code = entry.code;
            const message = try self.gpa.dupe(u8, entry.message);
            errdefer self.gpa.free(message);
            const spec_ref = try self.gpa.dupe(u8, entry.spec_ref);
            errdefer self.gpa.free(spec_ref);
            const entry_source = try self.gpa.dupe(u8, entry.source);
            errdefer self.gpa.free(entry_source);
            try self.findings.append(self.gpa, .{
                .origin = origin,
                .range = .{
                    .start = entry.range.start.offset,
                    .end = entry.range.end.offset,
                },
                .severity = entry.severity,
                .code = code,
                .message = message,
                .spec_ref = spec_ref,
                .source = entry_source,
            });
        }
    }

    /// `ImportCycle` / `UnknownFragment` / `TooDeep` arrive as bare errors
    /// from `Store.assembleRoot`. Recompute the same bounded walk here (it
    /// never touches sources) and, for `MissingSource`, identify the first
    /// reached part whose text the Store cannot resolve.
    pub fn addAssemblyFailure(self: *Report, root: RootId, err: anyerror) !void {
        const program = self.store.program(root.program) orelse {
            const message = try std.fmt.allocPrint(
                self.gpa,
                "pngine module '<unknown>' cannot be assembled: {s}",
                .{@errorName(err)},
            );
            errdefer self.gpa.free(message);
            try self.project_diags.append(self.gpa, .{
                .severity = .@"error",
                .code = WgslDiagnostic.Code.pngine_module_unassemblable,
                .message = message,
            });
            return;
        };

        const root_part: ?*const types.Part = if (root.index < program.parts.len)
            &program.parts[root.index]
        else
            null;
        const root_name: []const u8 = if (root_part) |part| part.name else "?";

        var failure: Assemble.Failure = .{ .root = root };
        var order: []u32 = &.{};
        const order_result = Assemble.collectOrderWithLimits(self.gpa, program, root, .{}, &failure);
        if (order_result) |value| {
            order = value;
        } else |_| {}
        defer if (order.len > 0) self.gpa.free(order);

        var related: std.ArrayList(Related) = .empty;
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
            const part: ?*const types.Part = if (part_index < program.parts.len)
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

        try self.project_diags.append(self.gpa, .{
            .severity = .@"error",
            .code = WgslDiagnostic.Code.pngine_module_unassemblable,
            .message = message,
            .program = root.program,
            .related = related,
        });
    }

    fn findMissingSource(self: *Report, root: RootId, order: []const u32) !?u32 {
        for (order) |part_index| {
            const id: OriginKey = .{ .program = root.program, .index = part_index };
            if (try self.partTextMissing(id)) return part_index;
        }
        const root_id: OriginKey = .{ .program = root.program, .index = root.index };
        if (try self.partTextMissing(root_id)) return root.index;
        return null;
    }

    fn partTextMissing(self: *Report, id: OriginKey) !bool {
        var text = self.store.textForPart(id) catch |err| switch (err) {
            error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => return true,
            else => return err,
        };
        text.deinit(self.gpa);
        return false;
    }

    pub fn addPassUnsupported(self: *Report, root: RootId) !void {
        const program = self.store.program(root.program) orelse return;
        if (root.index >= program.parts.len) return;
        const part = &program.parts[root.index];

        const message = try std.fmt.allocPrint(
            self.gpa,
            "pngine pass '{s}' requires generated bindings; semantic validation is unavailable for this context",
            .{part.name},
        );
        errdefer self.gpa.free(message);

        var related: std.ArrayList(Related) = .empty;
        errdefer freeRelatedList(self.gpa, &related);
        try appendRelated(self.gpa, &related, try self.rootRelated(root));

        try self.project_diags.append(self.gpa, .{
            .severity = .warning,
            .code = WgslDiagnostic.Code.pngine_pass_unsupported,
            .message = message,
            .program = root.program,
            .related = related,
        });
    }

    /// Check every reached part's `:requires` against the assembled module's
    /// parsed top-level declarations. `only` narrows the primary reports to
    /// the caller's requested origins; null checks every reached part.
    pub fn checkRequirements(
        self: *Report,
        root: RootId,
        module: ?*Ast.Module,
        only: ?[]const OriginKey,
    ) !void {
        const program = self.store.program(root.program) orelse return;
        const order = Assemble.collectOrderWithLimits(self.gpa, program, root, .{}, null) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer if (order.len > 0) self.gpa.free(order);

        try self.checkPartRequirements(root, program, root.index, module, only);
        for (order) |part_index| {
            try self.checkPartRequirements(root, program, part_index, module, only);
        }
    }

    fn checkPartRequirements(
        self: *Report,
        root: RootId,
        program: *const types.Program,
        part_index: u32,
        module: ?*Ast.Module,
        only: ?[]const OriginKey,
    ) !void {
        if (part_index >= program.parts.len) return;
        const part = &program.parts[part_index];
        if (part.requires.len == 0) return;

        const id: OriginKey = .{ .program = root.program, .index = part_index };
        if (only) |origins| {
            if (!containsOrigin(origins, id)) return;
        }

        const parsed = module orelse return;
        for (part.requires) |requirement| {
            if (moduleDeclares(parsed, requirement.name)) continue;
            try self.addMissingRequirement(root, program, part_index, requirement);
        }
    }

    fn addMissingRequirement(
        self: *Report,
        root: RootId,
        program: *const types.Program,
        part_index: u32,
        requirement: types.Requirement,
    ) !void {
        const part = &program.parts[part_index];
        const root_part = if (root.index < program.parts.len) &program.parts[root.index] else part;

        const message = try std.fmt.allocPrint(
            self.gpa,
            "fragment '{s}' requires '{s}', declared nowhere in pngine module '{s}'",
            .{ part.name, requirement.name, root_part.name },
        );
        errdefer self.gpa.free(message);

        var related: std.ArrayList(Related) = .empty;
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

        try self.project_diags.append(self.gpa, .{
            .severity = .@"error",
            .code = WgslDiagnostic.Code.pngine_missing_requirement,
            .message = message,
            .program = root.program,
            .related = related,
        });
    }

    // =====================================================================
    // Finish: policy, dedupe materialisation, output views
    // =====================================================================

    pub fn finish(self: *Report) !Result {
        var out: std.ArrayList(DiagnosticOut) = .empty;
        errdefer out.deinit(self.gpa);

        // Project-level diagnostics keep their discovery order.
        for (self.project_diags.items) |*diag| {
            try out.append(self.gpa, .{
                .severity = diag.severity,
                .code = diag.code,
                .message = diag.message,
                .origin = null,
                .program = diag.program,
                .related = diag.related.items,
            });
        }

        self.applyLintPolicy();
        self.dropSuppressedFindings();
        self.resolveFixConflicts();

        for (self.findings.items) |*finding| {
            try self.finalizeFinding(finding);
            try out.append(self.gpa, .{
                .severity = finding.severity,
                .code = finding.code,
                .message = finding.message,
                .spec_ref = finding.spec_ref,
                .source = finding.source,
                .origin = finding.origin,
                .range = finding.range,
                .related = finding.related.items,
                .fix = finding.fix,
                .data = finding.data,
                .roots = finding.roots.items,
            });
        }

        if (self.dropped or self.incomplete_reason != null) {
            const reason = self.incomplete_reason orelse
                "a diagnostic could not be projected to an author file";
            const message = try std.fmt.allocPrint(
                self.gpa,
                "pngine project context is incomplete: {s}; only local syntax is reported",
                .{reason},
            );
            self.tail_diags.append(self.gpa, .{
                .severity = .warning,
                .code = WgslDiagnostic.Code.pngine_context_incomplete,
                .message = message,
            }) catch |err| {
                self.gpa.free(message);
                return err;
            };
            const diag = &self.tail_diags.items[self.tail_diags.items.len - 1];
            try out.append(self.gpa, .{
                .severity = diag.severity,
                .code = diag.code,
                .message = diag.message,
                .origin = null,
                .related = diag.related.items,
            });
        }

        return .{ .items = try out.toOwnedSlice(self.gpa) };
    }

    /// Whole-unit policy. Liveness findings must hold in every root the
    /// linter could judge; the module-size rule needs one root context.
    fn applyLintPolicy(self: *Report) void {
        for (self.findings.items) |*finding| {
            if (finding.kind != .lint) continue;
            if (isLivenessCode(finding.code)) {
                if (!self.lintHoldsEverywhere(finding)) finding.suppressed = true;
            } else if (std.mem.eql(u8, finding.code, code_minify_size)) {
                if (self.roots.len > 1) finding.suppressed = true;
            }
        }
    }

    fn dropSuppressedFindings(self: *Report) void {
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

    fn lintHoldsEverywhere(self: *const Report, finding: *const Finding) bool {
        // A synthetic Report never records an analyzed root; there is
        // nothing to disprove the finding.
        if (self.lint_roots.items.len == 0) return true;
        for (self.lint_roots.items) |root| {
            if (!containsRoot(finding.roots.items, root)) return false;
        }
        return true;
    }

    /// Two findings may offer different rewrites for the same author range.
    /// A disagreement withholds both fixes. Findings in different files can
    /// share byte ranges, so origin participates in the comparison.
    fn resolveFixConflicts(self: *Report) void {
        for (self.findings.items, 0..) |*finding, index| {
            const mine = finding.fix orelse continue;
            for (self.findings.items[index + 1 ..]) |*other| {
                const theirs = other.fix orelse continue;
                if (!sameOrigin(mine.origin, theirs.origin)) continue;
                if (!rangeEql(mine.range, theirs.range)) continue;
                if (std.mem.eql(u8, mine.text, theirs.text)) continue;
                finding.fix_conflicted = true;
                other.fix_conflicted = true;
            }
        }
        for (self.findings.items) |*finding| {
            if (!finding.fix_conflicted) continue;
            if (finding.fix) |fix| {
                if (fix.text.len > 0) self.gpa.free(fix.text);
                finding.fix = null;
            }
        }
    }

    /// Materialise root relations and the E0100 composed wording. This is
    /// the only place the standalone validator message is extended.
    fn finalizeFinding(self: *Report, finding: *Finding) !void {
        const is_unresolved = std.mem.eql(u8, finding.code, WgslDiagnostic.Code.undefined_symbol);

        if (is_unresolved and finding.roots.items.len > 0) {
            const name = self.rootName(finding.roots.items[0]);
            const rewritten = try std.fmt.allocPrint(
                self.gpa,
                "{s} — declared nowhere in pngine module '{s}'",
                .{ finding.message, name orelse "?" },
            );
            self.gpa.free(finding.message);
            finding.message = rewritten;
        }

        const name_roots = finding.roots.items.len > 1 or
            is_unresolved or
            (self.semantic_root_count > 1 and finding.roots.items.len > 0);
        if (!name_roots) return;

        for (finding.roots.items) |root| {
            try appendRelated(self.gpa, &finding.related, try self.rootRelated(root));
        }
    }

    fn rootRelated(self: *Report, root: RootId) !?Related {
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
        self: *Report,
        program_id: types.ProgramId,
        part_index: u32,
        span: types.Span,
        comptime format: []const u8,
        args: anytype,
    ) !?Related {
        const program = self.store.program(program_id) orelse return null;
        if (part_index >= program.parts.len) return null;
        const doc = (try self.projectDoc(program_id)) orelse return null;
        _ = doc;
        const message = try std.fmt.allocPrint(self.gpa, format, args);
        return .{
            .target = .{ .project = .{ .program = program_id, .range = .{
                .start = span.start,
                .end = span.end,
            } } },
            .message = message,
        };
    }

    // =====================================================================
    // Lazy source/document caches
    // =====================================================================

    /// Resolve one origin part's current author text and path. Inline parts
    /// return null: there is no file an editor/CLI can name before the
    /// phase-04 virtual-document layer, and the shared layer keeps the
    /// phase-03 degradation rule for them.
    fn docFor(self: *Report, origin: OriginKey) !?*OriginDoc {
        if (self.docs.getPtr(origin)) |doc| return doc;

        const part = self.store.part(origin) orelse return null;
        const file = switch (part.origin) {
            .file => |source| source,
            .inline_code => return null,
        };
        const program = self.store.program(origin.program) orelse return null;

        const path = try resolvePath(self.gpa, program.document_path, file.path);
        errdefer self.gpa.free(path);

        var text = self.store.textForPart(origin) catch |err| switch (err) {
            error.SourceUnavailable, error.UnknownPart, error.UnknownProgram => return null,
            else => return err,
        };
        errdefer text.deinit(self.gpa);

        var line_index = try WgslDiagnostic.LineIndex.init(self.gpa, text.text);
        errdefer line_index.deinit(self.gpa);

        const gop = try self.docs.getOrPut(self.gpa, origin);
        if (gop.found_existing) {
            line_index.deinit(self.gpa);
            text.deinit(self.gpa);
            self.gpa.free(path);
            return gop.value_ptr;
        }
        gop.value_ptr.* = .{ .path = path, .text = text.text, .line_index = line_index };
        return gop.value_ptr;
    }

    fn projectDoc(self: *Report, program_id: types.ProgramId) !?*ProjectDoc {
        if (self.project_docs.get(program_id)) |doc| return doc;

        const program = self.store.program(program_id) orelse return null;
        const path = try self.gpa.dupe(u8, program.document_path);
        errdefer self.gpa.free(path);

        const text = self.store.provider.readText(self.gpa, program.document_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        errdefer self.gpa.free(text);

        // The graph's spans index the exact text that produced it. If the
        // document changed after the Store parsed it, a freshly read text
        // could turn a related range into a lie; omit the range instead.
        const hash = types.contentHash(text);
        if (!std.mem.eql(u8, &hash, &program.document_hash)) return null;

        var line_index = try WgslDiagnostic.LineIndex.init(self.gpa, text);
        errdefer line_index.deinit(self.gpa);

        const doc = try self.gpa.create(ProjectDoc);
        errdefer self.gpa.destroy(doc);
        doc.* = .{ .path = path, .text = text, .line_index = line_index };
        try self.project_docs.put(self.gpa, program_id, doc);
        return doc;
    }
};

// =========================================================================
// Free helpers
// =========================================================================

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

fn appendRoot(gpa: Allocator, roots: *std.ArrayList(RootId), id: RootId) !void {
    if (containsRoot(roots.items, id)) return;
    try roots.append(gpa, id);
}

fn containsRoot(roots: []const RootId, id: RootId) bool {
    for (roots) |root| {
        if (root.program == id.program and root.index == id.index) return true;
    }
    return false;
}

fn containsOrigin(origins: []const OriginKey, id: OriginKey) bool {
    for (origins) |origin| {
        if (origin.program == id.program and origin.index == id.index) return true;
    }
    return false;
}

fn sameOrigin(a: OriginKey, b: OriginKey) bool {
    return a.program == b.program and a.index == b.index;
}

fn rangeEql(a: ByteRange, b: ByteRange) bool {
    return a.start == b.start and a.end == b.end;
}

fn isLivenessCode(code: []const u8) bool {
    return std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_unused_vars) or
        std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_dead_code) or
        std.mem.eql(u8, code, WgslDiagnostic.Code.lint_no_unused_binding);
}

/// Resolve a `:file` value exactly as the Store does for membership:
/// relative to the program's document, then lexically normalized.
fn resolvePath(allocator: Allocator, document_path: []const u8, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return Path.normalizeLexical(allocator, relative);
    }
    const dir = std.fs.path.dirname(document_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, relative });
    defer allocator.free(joined);
    return Path.normalizeLexical(allocator, joined);
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

fn dupeOrEmpty(gpa: Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return &.{};
    return gpa.dupe(u8, value);
}

fn appendRelated(gpa: Allocator, list: *std.ArrayList(Related), relation: ?Related) !void {
    const item = relation orelse return;
    list.append(gpa, item) catch |err| {
        if (item.message.len > 0) gpa.free(item.message);
        return err;
    };
}

fn freeRelatedList(gpa: Allocator, list: *std.ArrayList(Related)) void {
    for (list.items) |item| {
        if (item.message.len > 0) gpa.free(item.message);
    }
    list.deinit(gpa);
    list.* = .empty;
}

fn freeHint(gpa: Allocator, data: WgslDiagnostic.QuickFixHint) void {
    switch (data) {
        .none, .duplicate_location, .vertex_missing_builtin_position => {},
        .did_you_mean, .unused_symbol, .feature_not_enabled => |s| {
            if (s.len > 0) gpa.free(s);
        },
        .type_mismatch => |tm| {
            if (tm.actual.len > 0) gpa.free(tm.actual);
            if (tm.expected.len > 0) gpa.free(tm.expected);
        },
        .lint_fix => |lf| {
            if (lf.text.len > 0) gpa.free(lf.text);
        },
    }
}

fn dupeHint(gpa: Allocator, data: WgslDiagnostic.QuickFixHint) WgslDiagnostic.QuickFixHint {
    return switch (data) {
        .none, .duplicate_location, .vertex_missing_builtin_position => data,
        .did_you_mean => |s| .{ .did_you_mean = gpa.dupe(u8, s) catch "" },
        .unused_symbol => |s| .{ .unused_symbol = gpa.dupe(u8, s) catch "" },
        .feature_not_enabled => |s| .{ .feature_not_enabled = gpa.dupe(u8, s) catch "" },
        .type_mismatch => |tm| .{ .type_mismatch = .{
            .actual = gpa.dupe(u8, tm.actual) catch "",
            .expected = gpa.dupe(u8, tm.expected) catch "",
        } },
        .lint_fix => |lf| .{ .lint_fix = .{
            .start_line = lf.start_line,
            .start_character = lf.start_character,
            .end_line = lf.end_line,
            .end_character = lf.end_character,
            .text = gpa.dupe(u8, lf.text) catch "",
        } },
    };
}
