//! pngine corpus acceptance gate (pngine-shaders phase 03, Task 6).
//!
//! Opt-in: this suite reads the read-only `inercia-2026` checkout supplied
//! through `-Dinercia=<path>`. It is a separate build step
//! (`zig build pngine-corpus-test -Dinercia=…`), never part of `zig build
//! test`, so the ordinary suite stays self-contained and a checkout without
//! the sibling still builds.
//!
//! The contracts encoded here:
//!   * the W0001 baseline on `clock/kernels/scene_lib.wgsl` is *derived*
//!     from the standalone linter and pinned as named fixtures; judging the
//!     same file inside `sceneCode` must not repeat a finding for any name
//!     the assembled project references, while genuinely unused names keep
//!     theirs;
//!   * `Transform2D` and `Surface` resolve from the assembled library, and
//!     the scene functions remain callable;
//!   * each of the four `demo` roots reports its own injected defect when it
//!     is the requested document, and no sibling root's defect leaks in;
//!   * `bounce` and `veclock` match the legacy standalone path exactly —
//!     the comparison is computed, not blessed.
//!
//! Every project read goes through the native `SourceProvider`; the only
//! filesystem access here is loading the corpus files into overlays/legacy
//! handlers, exactly as an editor's `didOpen` would.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const native_provider = @import("native_source_provider");
const corpus_config = @import("corpus_config");

const pngine = wgslender.Pngine;
const Types = pngine.Types;
const Store = pngine.Store;
const FileProvider = native_provider.FileProvider;

const testing = std.testing;
const allocator = testing.allocator;

const corpus_root: []const u8 = corpus_config.inercia_root;

const w0001_baseline = [_][]const u8{
    "PI",
    "TAU",
    "FAR",
    "identity2D",
    "transform2DAnchored",
    "toParent",
    "compose",
    "screenToWorld",
    "worldToScreen",
    "sdCircle",
    "sdRoundBox",
    "opUnion",
    "opIntersection",
    "opSubtract",
    "opSmoothUnion",
    "solid",
    "multiplyOpacity",
    "clipSurface",
    "renderCharacter",
};

const clock_scene_lib = "clock/kernels/scene_lib.wgsl";

const demo_roots = [_]struct {
    file: []const u8,
    injected: []const u8,
    missing: []const u8,
}{
    .{ .file = "demo/kernels/bg.wgsl", .injected = "injected_bg_defect", .missing = "demo_missing_bg" },
    .{ .file = "demo/kernels/squares.wgsl", .injected = "injected_squares_defect", .missing = "demo_missing_squares" },
    .{ .file = "demo/kernels/post.wgsl", .injected = "injected_post_defect", .missing = "demo_missing_post" },
    .{ .file = "demo/kernels/composite.wgsl", .injected = "injected_composite_defect", .missing = "demo_missing_composite" },
};

const legacy_cases = [_][]const u8{
    "bounce/kernels/bouncing-sq.wgsl",
    "veclock/kernels/clock_vec.wgsl",
};

const Corpus = struct {
    arena: std.heap.ArenaAllocator,
    provider: FileProvider,
    store: Store,
    handler: Handler,

    fn init(self: *Corpus) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.provider = .{ .io = std.testing.io };
        self.store = Store.init(allocator, self.provider.sourceProvider());
        errdefer self.store.deinit();

        // A wrong/missing `-Dinercia` path must fail loudly rather than
        // silently running zero assertions.
        const probe = try self.path("clock/program.sjon");
        _ = std.Io.Dir.cwd().readFileAlloc(std.testing.io, probe, self.arena.allocator(), .unlimited) catch {
            std.debug.print(
                "pngine corpus gate: cannot read '{s}'; pass -Dinercia=<path> pointing at the inercia-2026 checkout\n",
                .{probe},
            );
            return error.InerciaCorpusMissing;
        };

        const roots = [_][]const u8{
            try self.path("clock"),
            try self.path("demo"),
            try self.path("bounce"),
            try self.path("veclock"),
        };
        try self.store.setWorkspaceRoots(&roots);
        self.handler = Handler.init(allocator);
        self.handler.setPngineStore(&self.store);
    }

    fn deinit(self: *Corpus) void {
        self.handler.deinit();
        self.store.deinit();
        self.arena.deinit();
    }

    fn path(self: *Corpus, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ corpus_root, relative });
    }

    fn uri(self: *Corpus, relative: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "file://{s}", .{try self.path(relative)});
    }

    fn read(self: *Corpus, relative: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            try self.path(relative),
            self.arena.allocator(),
            .unlimited,
        );
    }

    fn rootFor(self: *Corpus, relative: []const u8) !Types.PartId {
        var set = try self.store.membershipsFor(try self.uri(relative));
        defer set.deinit(allocator);
        if (set.items.len == 0) return error.TestExpectedMembership;
        const membership = set.items[0];
        if (membership.containing_roots.len == 0) return error.TestExpectedRoot;
        return .{ .program = membership.program, .index = membership.containing_roots[0] };
    }

    fn validate(self: *Corpus, relative: []const u8) ![]Handler.LspDiagnostic {
        return self.handler.validatePngineDocument(try self.uri(relative), .{});
    }
};

fn isUnusedCode(code: []const u8) bool {
    return std.mem.eql(u8, code, wgslender.Diagnostic.Code.lint_no_unused_vars);
}

fn unusedName(diag: *const Handler.LspDiagnostic) ?[]const u8 {
    return switch (diag.data) {
        .unused_symbol => |name| name,
        else => null,
    };
}

fn hasUnusedName(diags: []const Handler.LspDiagnostic, name: []const u8) bool {
    for (diags) |diag| {
        if (!isUnusedCode(diag.code)) continue;
        if (unusedName(&diag)) |reported| {
            if (std.mem.eql(u8, reported, name)) return true;
        }
    }
    return false;
}

fn hasCodeMatching(diags: []const Handler.LspDiagnostic, code: []const u8, needle: []const u8) bool {
    for (diags) |diag| {
        if (!std.mem.eql(u8, diag.code, code)) continue;
        if (std.mem.indexOf(u8, diag.message, needle) != null) return true;
    }
    return false;
}

/// True when the assembled module references `name` anywhere. The
/// validator's own use-count is the same signal W0001 consults, read from
/// the parsed module rather than re-scanning text.
fn moduleUsesName(
    module: *const wgslender.Ast.Module,
    analysis: *const wgslender.Validator.AnalysisResult,
    name: []const u8,
) bool {
    for (module.symbols.items, 0..) |symbol, index| {
        if (!std.mem.eql(u8, symbol.original_name, name)) continue;
        if (analysis.useCount(@intCast(index)) > 0) return true;
    }
    return false;
}

fn countCode(diags: []const Handler.LspDiagnostic, code: []const u8) usize {
    var count: usize = 0;
    for (diags) |diag| {
        if (std.mem.eql(u8, diag.code, code)) count += 1;
    }
    return count;
}

fn dump(diags: []const Handler.LspDiagnostic) void {
    for (diags) |diag| {
        std.debug.print(
            "  {s}:{d}:{d} {s}: {s}\n",
            .{ diag.code, diag.range.start.line, diag.range.start.character, @tagName(diag.severity), diag.message },
        );
    }
}

/// The library call behind `wgslender lint` with no config: the
/// `@wgslender/recommended` pack. Returns the W0001 symbol names in report
/// order.
fn deriveStandaloneW0001(arena: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const source_z = try arena.dupeZ(u8, source);
    var analysis = try wgslender.analyzeWithOptions(arena, source_z, .{});
    defer analysis.deinit();

    var lint = try wgslender.Linter.run(arena, &analysis, .{
        .extends = &.{"@wgslender/recommended"},
    });
    defer lint.deinit(arena);

    var names: std.ArrayList([]const u8) = .empty;
    for (lint.diagnostics.items()) |entry| {
        if (!std.mem.eql(u8, entry.code, wgslender.Diagnostic.Code.lint_no_unused_vars)) continue;
        switch (entry.data) {
            .unused_symbol => |name| try names.append(arena, try arena.dupe(u8, name)),
            else => return error.MissingUnusedSymbolPayload,
        }
    }
    return names.toOwnedSlice(arena);
}

// =========================================================================
// C01/C02/C03/C04 — the measured clock fragment.
// =========================================================================

test "clock: the W0001 baseline loses only its false positives inside sceneCode" {
    var corpus: Corpus = undefined;
    try corpus.init();
    defer corpus.deinit();

    const source = try corpus.read(clock_scene_lib);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const derived = try deriveStandaloneW0001(arena.allocator(), source);

    // The derivation is the contract: a corpus edit that changes the
    // standalone result must fail here and be re-pinned deliberately.
    try testing.expectEqual(w0001_baseline.len, derived.len);
    for (w0001_baseline) |expected| {
        var found = false;
        for (derived) |actual| {
            if (std.mem.eql(u8, expected, actual)) found = true;
        }
        if (!found) {
            std.debug.print("standalone baseline no longer contains '{s}'; derived:\n", .{expected});
            for (derived) |actual| std.debug.print("  {s}\n", .{actual});
            return error.StaleW0001Baseline;
        }
    }

    const diags = try corpus.validate(clock_scene_lib);
    defer Handler.Diagnostics.freeDiagnostics(allocator, diags);

    // An independent oracle for "used by the project": the assembled
    // module's own symbol table, not a substring scan and not the finding
    // under test. `circle.wgsl` lives beside the clock kernels but is not a
    // part of `program.sjon`, so names only it references are genuinely
    // unused in `sceneCode`; the rest are the false positives this gate
    // exists to remove.
    const root = try corpus.rootFor(clock_scene_lib);
    const analysis = try corpus.handler.analyzeRoot(root);
    const module = analysis.result.module orelse return error.MissingAssembledModule;

    var used_in_project: usize = 0;
    var unused_in_project: usize = 0;
    var failures: usize = 0;
    for (w0001_baseline) |name| {
        const reported = hasUnusedName(diags, name);
        if (moduleUsesName(module, analysis.result, name)) {
            used_in_project += 1;
            if (reported) {
                std.debug.print("false W0001 for '{s}' in sceneCode\n", .{name});
                failures += 1;
            }
        } else {
            unused_in_project += 1;
            // A genuinely unused declaration keeps its finding: this proves
            // the composed lint is still judging liveness, not switched off.
            if (!reported) {
                std.debug.print("missing true W0001 for '{s}' in sceneCode\n", .{name});
                failures += 1;
            }
        }
    }
    if (failures > 0) {
        std.debug.print("composed diagnostics for {s}:\n", .{clock_scene_lib});
        dump(diags);
    }
    try testing.expect(used_in_project > 0);
    try testing.expect(unused_in_project > 0);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "clock sceneCode W0001 baseline: {d} names used by the project have no finding, {d} genuinely unused keep theirs\n",
        .{ used_in_project, unused_in_project },
    );

    // C02/C03/C04: sibling types resolve and scene functions are callable
    // from the assembled module. These are the three diagnostic families a
    // missing fragment boundary would produce.
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0200"));
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E0204"));
    try testing.expect(!hasCodeMatching(diags, "E0200", "Transform2D"));
    try testing.expect(!hasCodeMatching(diags, "E0200", "Surface"));
    for (diags) |diag| {
        if (std.mem.eql(u8, diag.code, "E0100") or
            std.mem.eql(u8, diag.code, "E0200") or
            std.mem.eql(u8, diag.code, "E0204"))
        {
            std.debug.print("unexpected unresolved scene_lib diagnostic: {s}: {s}\n", .{ diag.code, diag.message });
            return error.UnexpectedUnresolvedDiagnostic;
        }
    }
}

// =========================================================================
// C05 — the shared demo palette is judged in all four roots.
// =========================================================================

test "demo: declarations used by every root are not globally dead" {
    var corpus: Corpus = undefined;
    try corpus.init();
    defer corpus.deinit();

    const diags = try corpus.validate("demo/kernels/palette.wgsl");
    defer Handler.Diagnostics.freeDiagnostics(allocator, diags);

    const used_by_roots = [_][]const u8{
        "uvOf",
        "stagePoint",
        "palette",
        "rgb2hsv",
        "hsv2rgb",
        "mainColor",
        "GOLDEN_ANGLE",
        "SUPPORT_KEEP",
        "SUPPORT_LIFT",
        "SCENES",
        "STAGE_ASPECT",
    };
    for (used_by_roots) |name| {
        if (hasUnusedName(diags, name)) {
            std.debug.print("false W0001 for '{s}' shared by four roots\n", .{name});
            dump(diags);
            return error.FalseSharedUnused;
        }
    }
    // `params` is a binding each root reads, so W0003 must be suppressed too.
    try testing.expectEqual(@as(usize, 0), countCode(diags, wgslender.Diagnostic.Code.lint_no_unused_binding));
    // A genuinely unused declaration (TAU is read nowhere in the four roots)
    // still reports: this is a whole-unit judgement, not lint off.
    try testing.expect(hasUnusedName(diags, "TAU"));
    std.debug.print(
        "demo palette: {d} declarations used by the four roots have no W0001, W0003 suppressed, genuinely unused TAU retained\n",
        .{used_by_roots.len},
    );
}

// =========================================================================
// C44/C06 — each demo root's own finding appears for its own document.
// =========================================================================

test "demo: each of the four roots reports its own injected defect only" {
    var corpus: Corpus = undefined;
    try corpus.init();
    defer corpus.deinit();

    // Give each root a distinct unresolved name in an unsaved overlay. No
    // corpus file is written; the store's open-buffer layer is authoritative.
    for (demo_roots) |root| {
        const source = try corpus.read(root.file);
        const injected = try std.fmt.allocPrint(
            corpus.arena.allocator(),
            "{s}\nfn {s}() -> f32 {{ return {s}; }}\n",
            .{ source, root.injected, root.missing },
        );
        corpus.handler.notifyPngineBuffer(try corpus.uri(root.file), injected);
    }

    for (demo_roots, 0..) |root, index| {
        const diags = try corpus.validate(root.file);
        defer Handler.Diagnostics.freeDiagnostics(allocator, diags);

        if (!hasCodeMatching(diags, "E0100", root.missing)) {
            std.debug.print("root '{s}' did not report its own defect '{s}':\n", .{ root.file, root.missing });
            dump(diags);
            return error.MissingOwnRootFinding;
        }
        for (demo_roots, 0..) |other, other_index| {
            if (other_index == index) continue;
            if (hasCodeMatching(diags, "E0100", other.missing)) {
                std.debug.print(
                    "root '{s}' leaked sibling defect '{s}' from '{s}'\n",
                    .{ root.file, other.missing, other.file },
                );
                dump(diags);
                return error.LeakedSiblingRootFinding;
            }
        }
        std.debug.print(
            "demo root '{s}': own E0100 '{s}' present; three sibling defects absent\n",
            .{ root.file, root.missing },
        );
    }
}

// =========================================================================
// C49 — bounce and veclock are byte-for-byte the legacy standalone output.
// =========================================================================

fn diagnosticsEqual(a: Handler.LspDiagnostic, b: Handler.LspDiagnostic) bool {
    if (!std.meta.eql(a.range, b.range)) return false;
    if (a.severity != b.severity) return false;
    if (!std.mem.eql(u8, a.code, b.code)) return false;
    if (!std.mem.eql(u8, a.message, b.message)) return false;
    if (!std.mem.eql(u8, a.spec_url, b.spec_url)) return false;
    if (!std.mem.eql(Handler.DiagnosticTag, a.tags, b.tags)) return false;
    if (a.related.len != b.related.len) return false;
    for (a.related, b.related) |rel_a, rel_b| {
        if (!std.mem.eql(u8, rel_a.uri, rel_b.uri)) return false;
        if (!std.meta.eql(rel_a.range, rel_b.range)) return false;
        if (!std.mem.eql(u8, rel_a.message, rel_b.message)) return false;
    }
    if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
    switch (a.data) {
        .unused_symbol => |name_a| {
            const name_b = b.data.unused_symbol;
            if (!std.mem.eql(u8, name_a, name_b)) return false;
        },
        .did_you_mean => |name_a| {
            const name_b = b.data.did_you_mean;
            if (!std.mem.eql(u8, name_a, name_b)) return false;
        },
        .lint_fix => |fix_a| {
            const fix_b = b.data.lint_fix;
            if (!std.mem.eql(u8, fix_a.text, fix_b.text)) return false;
            if (fix_a.start_line != fix_b.start_line or
                fix_a.start_character != fix_b.start_character or
                fix_a.end_line != fix_b.end_line or
                fix_a.end_character != fix_b.end_character) return false;
        },
        else => {},
    }
    return true;
}

test "bounce and veclock: composed diagnostics equal the legacy standalone set" {
    var corpus: Corpus = undefined;
    try corpus.init();
    defer corpus.deinit();

    for (legacy_cases) |relative| {
        const uri = try corpus.uri(relative);
        const source = try corpus.read(relative);

        var legacy = Handler.init(allocator);
        defer legacy.deinit();
        try legacy.openDocument(uri, source, 1);

        const expected = try Handler.Diagnostics.validateDocumentFull(&legacy, uri);
        defer Handler.Diagnostics.freeDiagnostics(allocator, expected);

        try corpus.handler.openDocument(uri, source, 1);
        const actual = try Handler.Diagnostics.validateDocumentFull(&corpus.handler, uri);
        defer Handler.Diagnostics.freeDiagnostics(allocator, actual);

        std.debug.print(
            "legacy corpus root '{s}': {d} standalone diagnostics, {d} composed\n",
            .{ relative, expected.len, actual.len },
        );
        try testing.expectEqual(expected.len, actual.len);
        for (expected) |want| {
            var matched = false;
            for (actual) |got| {
                if (diagnosticsEqual(want, got)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                std.debug.print("composed set is missing standalone diagnostic for '{s}': {s}: {s}\n", .{
                    relative, want.code, want.message,
                });
                std.debug.print("composed set:\n", .{});
                dump(actual);
                return error.LegacyDiagnosticMismatch;
            }
        }
    }
}
