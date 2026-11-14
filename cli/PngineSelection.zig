//! pngine project selection for the native CLI (pngine-shaders phase 05,
//! Task 1).
//!
//! This module answers one question for a CLI invocation: which pngine
//! program and which of its shader-module roots does the input belong to?
//! Explicit `--project <file.sjon>` selection loads exactly that document;
//! discovery-based selection reuses the store's ancestor walk and reverse
//! membership index. Neither path opens a project document directly: the
//! only filesystem binding is `FileProvider`, and every project read goes
//! through `Store`'s `SourceProvider`.
//!
//! Selection errors are usage errors (exit 2) in the CLI. `Failure` carries
//! the preformatted message so the caller can print one located line naming
//! the offending path, root, or project.

const std = @import("std");
const build_options = @import("build_options");
const wgslender = @import("wgslender");

/// Whether this graph compiled pngine project support in. The native CLI
/// and LSP graphs carry it when SJON resolved; `-Dlsp=false` builds the
/// CLI without it and must still compile, so every project-typed
/// declaration below is conditional.
pub const enabled = build_options.pngine_support;

pub const Store = if (enabled) wgslender.Pngine.Store else void;
pub const Types = if (enabled) wgslender.Pngine.Types else struct {};
pub const RootId = if (enabled) wgslender.Pngine.RootId else struct { program: u32, index: u32 };
pub const ProgramId = if (enabled) wgslender.Pngine.Types.ProgramId else u32;
pub const PartId = if (enabled) wgslender.Pngine.Types.PartId else struct { program: u32, index: u32 };

/// The three CLI-only selectors, in the shape the option-spec dispatcher
/// writes. Kept here rather than in `cli/main.zig` so the selection module
/// and the spec table cannot drift.
pub const Flags = struct {
    project: ?[]const u8 = null,
    root: ?[]const u8 = null,
    no_project: bool = false,
};

/// The largest explicit project document. Mirrors SJON's asserted parser
/// ceiling (`sjon.Binary.MAX_FILE_SIZE`); discovery's own 64 MiB input
/// budget deliberately does not apply to `--project`.
pub const default_max_project_bytes: usize = if (enabled)
    wgslender.Pngine.Extract.max_document_bytes
else
    1 << 28;

pub const SelectOptions = struct {
    max_project_bytes: usize = default_max_project_bytes,
};

pub const Error = std.mem.Allocator.Error || error{
    NoProject,
    NoProjectWithSelectors,
    StdinRequiresBothSelectors,
    ProjectIsDirectory,
    ProjectUnreadable,
    ProjectTooLarge,
    InvalidProject,
    DuplicateRootName,
    UnknownRoot,
    RootDoesNotContainInput,
    RootRequiresProject,
    AmbiguousRoots,
    StdinPassRoot,
    StdinInlineRoot,
    PngineUnsupported,
};

/// Preformatted usage-error payload. `message` is allocated with the
/// allocator passed to the failing call (the store's `gpa` in practice);
/// call `deinit` exactly once.
pub const Failure = struct {
    /// The error tag that produced this message, for tests and callers
    /// that branch on the failure kind.
    kind: ?anyerror = null,
    message: []u8 = &.{},

    pub fn deinit(self: *Failure, gpa: std.mem.Allocator) void {
        if (self.message.len > 0) gpa.free(self.message);
        self.* = .{};
    }
};

/// One selected program and the roots to process, in stable program/form
/// order. `input_part` is the part that owns the input file (or the root
/// itself), or null when the text arrives on stdin.
pub const ProjectSelection = struct {
    program: ProgramId,
    input_part: ?PartId,
    roots: []const RootId,

    pub fn deinit(self: *ProjectSelection, gpa: std.mem.Allocator) void {
        if (self.roots.len > 0) gpa.free(self.roots);
        self.* = .{ .program = 0, .input_part = null, .roots = &.{} };
    }
};

/// True when the invocation asked to resolve a project explicitly or by
/// discovery. `--no-project` alone never selects: it is the single-source
/// escape hatch and must be byte-identical to today's CLI.
pub fn selectionRequested(flags: Flags) bool {
    if (flags.no_project) return false;
    return flags.project != null or flags.root != null;
}

/// Validate selector shape before any input is read, so `stdin` with only
/// one selector exits 2 without blocking on a pipe.
pub fn validateFlagShape(
    flags: Flags,
    stdin: bool,
    failure: ?*Failure,
    allocator: std.mem.Allocator,
) Error!void {
    if (comptime !enabled) {
        if (flags.project == null and flags.root == null) return;
        return fail(
            failure,
            allocator,
            error.PngineUnsupported,
            "--project/--root are unavailable in this build (pngine project support is compiled out)",
            .{},
        );
    }
    if (flags.no_project and (flags.project != null or flags.root != null)) {
        return fail(
            failure,
            allocator,
            error.NoProjectWithSelectors,
            "--no-project cannot be combined with --project or --root",
            .{},
        );
    }
    if (stdin and flags.project == null and flags.root == null) return;
    if (stdin and (flags.project == null or flags.root == null)) {
        return fail(
            failure,
            allocator,
            error.StdinRequiresBothSelectors,
            "stdin requires both --project and --root (missing {s})",
            .{if (flags.project == null) "--project" else "--root"},
        );
    }
}

/// Select one program and its roots. Convenience wrapper that discards the
/// failure message (kept for the interface recorded in the phase plan).
pub fn selectProject(
    store: *Store,
    input_path: ?[]const u8,
    project_path: ?[]const u8,
    root_name: ?[]const u8,
    no_project: bool,
) !ProjectSelection {
    var failure = Failure{};
    defer failure.deinit(store.gpa);
    return selectProjectWithOptions(
        store,
        input_path,
        project_path,
        root_name,
        no_project,
        .{},
        &failure,
    );
}

/// Selection with a caller-owned failure payload.
pub fn selectProjectWithFailure(
    store: *Store,
    input_path: ?[]const u8,
    project_path: ?[]const u8,
    root_name: ?[]const u8,
    no_project: bool,
    failure: ?*Failure,
) Error!ProjectSelection {
    return selectProjectWithOptions(store, input_path, project_path, root_name, no_project, .{}, failure);
}

/// Selection with explicit limits (tests lower `max_project_bytes` so the
/// overflow arm runs without allocating a 256 MiB fixture).
pub fn selectProjectWithOptions(
    store: *Store,
    input_path: ?[]const u8,
    project_path: ?[]const u8,
    root_name: ?[]const u8,
    no_project: bool,
    options: SelectOptions,
    failure: ?*Failure,
) Error!ProjectSelection {
    const gpa = store.gpa;
    resetFailure(failure, gpa);

    const flags = Flags{
        .project = project_path,
        .root = root_name,
        .no_project = no_project,
    };
    try validateFlagShape(flags, input_path == null, failure, gpa);

    if (no_project) {
        return fail(
            failure,
            gpa,
            error.NoProject,
            "--no-project keeps the input as a single source; no pngine project was selected",
            .{},
        );
    }

    if (project_path) |path| {
        return selectExplicit(store, input_path, path, root_name, options, failure);
    }
    if (input_path) |input| {
        return selectDiscovered(store, input, root_name, failure);
    }
    return fail(
        failure,
        gpa,
        error.NoProject,
        "stdin has no pngine project; pass --project and --root to select one",
        .{},
    );
}

const ScopedProvider = struct {
    inner: Types.SourceProvider,
    document_path: []const u8,
    document_dir: []const u8,

    fn sourceProvider(self: *ScopedProvider) Types.SourceProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Types.SourceProvider.VTable{
        .read_text = readText,
        .candidates = candidates,
    };

    fn readText(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *ScopedProvider = @ptrCast(@alignCast(context));
        return self.inner.readText(allocator, path);
    }

    fn candidates(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        dir: []const u8,
    ) anyerror![]Types.Candidate {
        const self: *ScopedProvider = @ptrCast(@alignCast(context));
        const normalized = std.fs.path.resolve(allocator, &.{dir}) catch return error.OutOfMemory;
        defer allocator.free(normalized);
        // An explicit project loads exactly one document. Reporting no
        // other candidate keeps sibling `.sjon` files out of the store and
        // makes `--project` independent of directory layout or size.
        if (!std.mem.eql(u8, normalized, self.document_dir)) {
            return allocator.alloc(Types.Candidate, 0);
        }
        const path = try allocator.dupe(u8, self.document_path);
        errdefer allocator.free(path);
        const list = try allocator.alloc(Types.Candidate, 1);
        list[0] = .{ .path = path, .kind = .file };
        return list;
    }
};

fn selectExplicit(
    store: *Store,
    input_path: ?[]const u8,
    project_path: []const u8,
    root_name: ?[]const u8,
    options: SelectOptions,
    failure: ?*Failure,
) Error!ProjectSelection {
    const gpa = store.gpa;
    const document_path = std.fs.path.resolve(gpa, &.{project_path}) catch return error.OutOfMemory;
    defer gpa.free(document_path);
    const document_dir = std.fs.path.dirname(document_path) orelse ".";

    if (try candidateKind(store, document_path)) |kind| {
        if (kind == .directory) {
            return fail(
                failure,
                gpa,
                error.ProjectIsDirectory,
                "--project '{s}' is a directory; expected one .sjon project document",
                .{project_path},
            );
        }
    }

    // Read through the store's provider. This is also the only place the
    // explicit path is checked against SJON's parser ceiling: discovery's
    // 64 MiB input budget must not turn an over-size --project into an
    // assert inside sjon.parse.
    const text = store.provider.readText(gpa, document_path) catch |err| {
        if (err == error.IsDir) {
            return fail(
                failure,
                gpa,
                error.ProjectIsDirectory,
                "--project '{s}' is a directory; expected one .sjon project document",
                .{project_path},
            );
        }
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(
            failure,
            gpa,
            error.ProjectUnreadable,
            "cannot read project document '{s}': {s}",
            .{ project_path, @errorName(err) },
        );
    };
    defer gpa.free(text);

    if (text.len > options.max_project_bytes) {
        return fail(
            failure,
            gpa,
            error.ProjectTooLarge,
            "project document '{s}':1:1: {d} bytes exceeds the maximum of {d}",
            .{ project_path, text.len, options.max_project_bytes },
        );
    }

    // Load exactly this document through the store's own discovery +
    // extraction path, with a provider view that exposes no sibling
    // candidates. The store still owns every read and every allocation.
    var scoped = ScopedProvider{
        .inner = store.provider,
        .document_path = document_path,
        .document_dir = document_dir,
    };
    const saved_provider = store.provider;
    const saved_limits = store.limits;
    store.provider = scoped.sourceProvider();
    if (store.limits.max_input_bytes < text.len) store.limits.max_input_bytes = text.len;
    defer {
        store.provider = saved_provider;
        store.limits = saved_limits;
    }

    store.setWorkspaceRoots(&.{document_dir}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(
            failure,
            gpa,
            error.InvalidProject,
            "cannot load pngine project '{s}': {s}",
            .{ project_path, @errorName(err) },
        );
    };

    const program_id = store.programForDocument(document_path) orelse
        return invalidProject(store, document_path, text, failure);
    const program = store.program(program_id).?;

    if (input_path) |input| {
        var memberships = store.membershipsFor(input) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return fail(
                failure,
                gpa,
                error.NoProject,
                "cannot resolve '{s}' in project '{s}': {s}",
                .{ input, project_path, @errorName(err) },
            );
        };
        defer memberships.deinit(gpa);

        const membership = membershipForProgram(&memberships, program_id) orelse
            return fail(
                failure,
                gpa,
                error.NoProject,
                "input '{s}' is not part of pngine project '{s}'",
                .{ input, document_path },
            );
        return finishFromMembership(store, program_id, program, input, membership.part, membership.containing_roots, root_name, failure);
    }

    // stdin + both selectors: the root's own text is replaced by the
    // caller after selection, so no input part exists yet.
    return finishFromMembership(store, program_id, program, null, null, &.{}, root_name, failure);
}

fn invalidProject(
    store: *Store,
    document_path: []const u8,
    text: []const u8,
    failure: ?*Failure,
) Error!ProjectSelection {
    const gpa = store.gpa;
    var result = wgslender.Pngine.Extract.extractWithOptions(gpa, document_path, text, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(
            failure,
            gpa,
            error.InvalidProject,
            "cannot parse pngine project '{s}': {s}",
            .{ document_path, @errorName(err) },
        );
    };
    defer result.deinit(gpa);

    var chosen: ?wgslender.Pngine.Types.Diagnostic = null;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code == .duplicate_part_name) {
            chosen = diagnostic;
            break;
        }
        if (chosen == null) chosen = diagnostic;
    }
    if (chosen) |diagnostic| {
        var line: usize = 1;
        var column: usize = 1;
        locate(text, diagnostic.span.start, &line, &column);
        const kind: Error = if (diagnostic.code == .duplicate_part_name)
            error.DuplicateRootName
        else
            error.InvalidProject;
        return fail(
            failure,
            gpa,
            kind,
            "{s}:{d}:{d}: {s}",
            .{ document_path, line, column, diagnostic.message },
        );
    }
    return fail(
        failure,
        gpa,
        error.InvalidProject,
        "cannot load pngine project '{s}'",
        .{document_path},
    );
}

fn selectDiscovered(
    store: *Store,
    input_path: []const u8,
    root_name: ?[]const u8,
    failure: ?*Failure,
) Error!ProjectSelection {
    const gpa = store.gpa;
    var memberships = store.membershipsFor(input_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(
            failure,
            gpa,
            if (root_name == null) error.NoProject else error.RootRequiresProject,
            "cannot discover a pngine project containing '{s}': {s}",
            .{ input_path, @errorName(err) },
        );
    };
    defer memberships.deinit(gpa);

    if (memberships.items.len == 0) {
        if (root_name) |name| {
            return fail(
                failure,
                gpa,
                error.RootRequiresProject,
                "--root '{s}' requires a pngine project containing '{s}', and none was discovered",
                .{ name, input_path },
            );
        }
        return fail(
            failure,
            gpa,
            error.NoProject,
            "no pngine project contains '{s}'; it stays a single source",
            .{input_path},
        );
    }

    // Nearest project from the input file's directory. The store's
    // ancestor walk supplies every candidate; this layer only breaks ties
    // deterministically (shortest ancestor distance, then document path).
    var best_program: ?ProgramId = null;
    var best_score: usize = std.math.maxInt(usize);
    var best_path: []const u8 = "";
    for (memberships.items) |membership| {
        const program = store.program(membership.program) orelse continue;
        const score = ancestorScore(program.document_path, input_path);
        if (score < best_score or
            (score == best_score and std.mem.lessThan(u8, program.document_path, best_path)))
        {
            best_program = membership.program;
            best_score = score;
            best_path = program.document_path;
        }
    }

    const program_id = best_program orelse return fail(
        failure,
        gpa,
        error.NoProject,
        "no pngine project contains '{s}'; it stays a single source",
        .{input_path},
    );
    const program = store.program(program_id).?;
    const membership = membershipForProgram(&memberships, program_id).?;
    return finishFromMembership(store, program_id, program, input_path, membership.part, membership.containing_roots, root_name, failure);
}

fn finishFromMembership(
    store: *Store,
    program_id: ProgramId,
    program: *const wgslender.Pngine.Types.Program,
    input_path: ?[]const u8,
    input_part: ?PartId,
    containing_roots: []const u32,
    root_name: ?[]const u8,
    failure: ?*Failure,
) Error!ProjectSelection {
    const gpa = store.gpa;
    if (root_name) |name| {
        const index = findRoot(program, name) orelse {
            const available = try rootNamesAlloc(gpa, program, null);
            defer gpa.free(available);
            return fail(
                failure,
                gpa,
                error.UnknownRoot,
                "unknown root '{s}' in '{s}'; available roots: {s}",
                .{ name, program.document_path, available },
            );
        };
        if (input_part != null and !containsRoot(containing_roots, index)) {
            return fail(
                failure,
                gpa,
                error.RootDoesNotContainInput,
                "root '{s}' does not contain the input file '{s}' in '{s}'",
                .{ name, input_path orelse "<stdin>", program.document_path },
            );
        }
        const roots = try gpa.alloc(RootId, 1);
        roots[0] = .{ .program = program_id, .index = index };
        return .{ .program = program_id, .input_part = input_part, .roots = roots };
    }

    if (input_part == null) {
        return fail(
            failure,
            gpa,
            error.StdinRequiresBothSelectors,
            "stdin requires both --project and --root",
            .{},
        );
    }

    var roots: std.ArrayList(RootId) = .empty;
    errdefer roots.deinit(gpa);
    for (program.roots) |index| {
        if (program.parts[index].kind != .shader_module) continue;
        if (!containsRoot(containing_roots, index)) continue;
        try roots.append(gpa, .{ .program = program_id, .index = index });
    }
    if (roots.items.len == 0) {
        return fail(
            failure,
            gpa,
            error.NoProject,
            "no shader-module root in '{s}' contains the input",
            .{program.document_path},
        );
    }
    return .{ .program = program_id, .input_part = input_part, .roots = try roots.toOwnedSlice(gpa) };
}

/// Enforce the artifact-command rule: exactly one root, or a usage error
/// naming every available root so the user can pick one with `--root`.
pub fn requireSingleRoot(
    store: *Store,
    selection: *const ProjectSelection,
    input_path: ?[]const u8,
    failure: ?*Failure,
    allocator: std.mem.Allocator,
) Error!RootId {
    if (selection.roots.len == 1) return selection.roots[0];

    const gpa = store.gpa;
    const available = try selectionRootNamesAlloc(gpa, store, selection);
    defer gpa.free(available);
    return fail(
        failure,
        allocator,
        error.AmbiguousRoots,
        "input '{s}' is in {d} pngine roots; choose one with --root (available: {s})",
        .{ input_path orelse "<stdin>", selection.roots.len, available },
    );
}

/// Replace only the selected root's own author text with stdin. Imports
/// keep coming from the project's sources; pass roots and inline-code
/// roots have no file of their own to replace and refuse.
pub fn applyStdinOverlay(
    store: *Store,
    selection: *const ProjectSelection,
    text: []const u8,
    failure: ?*Failure,
    allocator: std.mem.Allocator,
) Error!void {
    const gpa = store.gpa;
    if (selection.roots.len != 1) {
        const available = try selectionRootNamesAlloc(gpa, store, selection);
        defer gpa.free(available);
        return fail(
            failure,
            allocator,
            error.AmbiguousRoots,
            "stdin requires exactly one selected root (available: {s})",
            .{available},
        );
    }

    const root = selection.roots[0];
    const part = store.part(root) orelse return fail(
        failure,
        allocator,
        error.NoProject,
        "selected root no longer exists in the store",
        .{},
    );

    if (part.kind == .pass) {
        return fail(
            failure,
            allocator,
            error.StdinPassRoot,
            "stdin cannot replace pass root '{s}'; pass roots generate their own module",
            .{part.name},
        );
    }

    switch (part.origin) {
        .inline_code => return fail(
            failure,
            allocator,
            error.StdinInlineRoot,
            "stdin cannot replace inline root '{s}'; it has no author file",
            .{part.name},
        ),
        .file => |file| {
            const program = store.program(root.program).?;
            const source_path = try resolveSourcePath(gpa, program.document_path, file.path);
            defer gpa.free(source_path);
            store.upsertBuffer(source_path, text, .open_buffer) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return fail(
                    failure,
                    allocator,
                    error.NoProject,
                    "cannot overlay stdin on '{s}': {s}",
                    .{ source_path, @errorName(err) },
                );
            };
        },
    }
}

fn fail(
    failure: ?*Failure,
    allocator: std.mem.Allocator,
    kind: Error,
    comptime format: []const u8,
    args: anytype,
) Error {
    if (failure) |f| {
        if (f.message.len > 0) allocator.free(f.message);
        f.message = std.fmt.allocPrint(allocator, format, args) catch &.{};
        f.kind = kind;
    }
    return kind;
}

fn resetFailure(failure: ?*Failure, allocator: std.mem.Allocator) void {
    if (failure) |f| {
        if (f.message.len > 0) allocator.free(f.message);
        f.* = .{};
    }
}

fn candidateKind(store: *Store, path: []const u8) Error!?Types.CandidateKind {
    const gpa = store.gpa;
    const dir = std.fs.path.dirname(path) orelse ".";
    const entries = store.provider.candidates(gpa, dir) catch return null;
    defer Types.deinitCandidates(gpa, entries);

    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;
    for (entries) |entry| {
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), base)) return entry.kind;
    }
    return null;
}

fn membershipForProgram(
    memberships: *const Types.MembershipSet,
    program: ProgramId,
) ?Types.Membership {
    for (memberships.items) |membership| {
        if (membership.program == program) return membership;
    }
    return null;
}

fn findRoot(program: *const wgslender.Pngine.Types.Program, name: []const u8) ?u32 {
    for (program.roots) |index| {
        if (std.mem.eql(u8, program.parts[index].name, name)) return index;
    }
    return null;
}

fn containsRoot(roots: []const u32, index: u32) bool {
    for (roots) |candidate| {
        if (candidate == index) return true;
    }
    return false;
}

fn rootNamesAlloc(
    allocator: std.mem.Allocator,
    program: *const wgslender.Pngine.Types.Program,
    only: ?[]const RootId,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    if (only) |roots| {
        for (roots) |root| {
            const part = program.parts[root.index];
            if (!first) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, part.name);
            first = false;
        }
    } else {
        for (program.roots) |index| {
            if (!first) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, program.parts[index].name);
            first = false;
        }
    }
    if (first) try buf.appendSlice(allocator, "none");
    return buf.toOwnedSlice(allocator);
}

fn selectionRootNamesAlloc(
    allocator: std.mem.Allocator,
    store: *const Store,
    selection: *const ProjectSelection,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (selection.roots, 0..) |root, index| {
        if (index > 0) try buf.appendSlice(allocator, ", ");
        const part = store.part(root) orelse continue;
        try buf.appendSlice(allocator, part.name);
    }
    return buf.toOwnedSlice(allocator);
}

fn resolveSourcePath(allocator: std.mem.Allocator, document_path: []const u8, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return std.fs.path.resolve(allocator, &.{relative});
    }
    const dir = std.fs.path.dirname(document_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, relative });
    defer allocator.free(joined);
    return std.fs.path.resolve(allocator, &.{joined});
}

fn locate(text: []const u8, offset: usize, line: *usize, column: *usize) void {
    line.* = 1;
    column.* = 1;
    const end = @min(offset, text.len);
    for (text[0..end]) |c| {
        if (c == '\n') {
            line.* += 1;
            column.* = 1;
        } else {
            column.* += 1;
        }
    }
}

fn ancestorScore(program_path: []const u8, input_path: []const u8) usize {
    const document_dir = std.fs.path.dirname(program_path) orelse ".";
    const input_dir = std.fs.path.dirname(input_path) orelse ".";
    if (isUnder(document_dir, input_dir)) {
        return pathDepth(input_dir) - pathDepth(document_dir);
    }
    return 1_000_000 + pathDepth(document_dir);
}

fn isUnder(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (child.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child[parent.len] == std.fs.path.sep;
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |_| depth += 1;
    return depth;
}

/// Native filesystem binding of `SourceProvider`. This is the CLI's only
/// implementation that opens a path, and it opens project text solely
/// through `readText`; selection code above this boundary never does.
pub const FileProvider = struct {
    io: std.Io = undefined,

    pub fn sourceProvider(self: *FileProvider) Types.SourceProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Types.SourceProvider.VTable{
        .read_text = readText,
        .candidates = candidates,
    };

    fn readText(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited);
    }

    fn candidates(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        dir: []const u8,
    ) anyerror![]Types.Candidate {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        var opened = try std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true });
        defer opened.close(self.io);

        var list: std.ArrayList(Types.Candidate) = .empty;
        errdefer {
            for (list.items) |candidate| allocator.free(candidate.path);
            list.deinit(allocator);
        }

        var it = opened.iterateAssumeFirstIteration();
        while (try it.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const kind: Types.CandidateKind = switch (entry.kind) {
                .directory => .directory,
                else => .file,
            };
            const child = try std.fs.path.join(allocator, &.{ dir, entry.name });
            errdefer allocator.free(child);
            try list.append(allocator, .{ .path = child, .kind = kind });
        }
        return list.toOwnedSlice(allocator);
    }
};
