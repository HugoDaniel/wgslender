//! Artifact commands over one selected pngine root (pngine-shaders
//! phase 05, Task 3).
//!
//! `reflect`, `minify`, and `compile` need exactly one shader-module root.
//! This module resolves that root through the shared selection layer,
//! assembles the unit through the `Store`, and feeds `Assembled.text`
//! through the *existing* reflect, minifier, and compiler pipelines. It
//! does not fork a second pipeline and does not re-derive option
//! precedence: the caller passes the options the CLI already resolved from
//! defaults, config file, and flags.
//!
//! ## Coordinates
//!
//! Diagnostics are author-facing: every parse/compile error is mapped
//! through the phase-02 segments back to the part and byte offset that
//! wrote it, then printed against that author file. Reflection is the
//! opposite: its numeric `nameOffset`, `declSpan`, and `typeSpan` fields
//! index `Assembled.text`, because that is the module the reflector read.
//! The assembled text is imports-first, so those offsets are not author
//! offsets and must never be relabelled as such; consumers that need
//! author-local spans must translate them through the mapping layer.
//!
//! Minified source maps are author-facing as well: the minifier's map is
//! decoded in assembled coordinates and re-encoded through the same
//! segments by `pngine.SourceMaps`, so `sources[]` names the user's files
//! (or inline virtual URIs) and every source position is author-local.
//! Generated positions and names are preserved; a mapping with no honest
//! origin is dropped with one warning naming the root.
//!
//! ## Suppression
//!
//! Parse/compile failures follow the artifact commands' failure policy:
//! map the diagnostics, emit no artifact (no JSON, no minified text, no
//! `.wasm`), and exit 1. Usage failures (more than one containing root or a
//! pass root) emit no artifact and exit 2.

const std = @import("std");
const wgslender = @import("wgslender");
const PngineSelection = @import("PngineSelection");

const pngine = wgslender.Pngine;
const SourceMaps = pngine.SourceMaps;
const Allocator = std.mem.Allocator;
const Diagnostic = wgslender.Diagnostic;

pub const Command = enum { reflect, minify, compile };

pub const Config = struct {
    reflect_compact: bool = false,
    reflect_version: wgslender.Reflect.JsonVersion = .v2,
    /// The fully resolved minifier options (defaults < config < flags),
    /// reused unchanged for `minify` and for `compile`'s minification.
    minify_options: wgslender.Minifier.Options = wgslender.Minifier.defaultOptions(),
};

/// One completed artifact run. `artifact` is the exact byte sequence the
/// caller writes on success: reflection JSON (with its trailing newline),
/// minified WGSL, or the `.wasm` binary. `diagnostics` is the fully
/// rendered stderr text for a failure, or the report-level warning for
/// dropped source-map entries on an otherwise successful minify.
/// `source_map` is present when minify generated a map; the caller writes
/// the external file or appends the inline comment exactly as the
/// single-source path does. Owns an internal arena.
pub const Result = struct {
    artifact: []const u8 = &.{},
    diagnostics: []const u8 = &.{},
    exit_code: u8 = 0,
    original_size: usize = 0,
    wasm_size: usize = 0,
    source_map: ?wgslender.SourceMap.Result = null,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        _ = allocator;
        self._arena.deinit();
        self.* = undefined;
    }
};

/// The command's payload before it is attached to the owning arena. Kept
/// separate so one `ArenaAllocator` value lives in `run`: helpers receive
/// only its allocator, never a copy of the arena itself.
const Outcome = struct {
    artifact: []const u8 = &.{},
    diagnostics: []const u8 = &.{},
    exit_code: u8 = 0,
    original_size: usize = 0,
    wasm_size: usize = 0,
    source_map: ?wgslender.SourceMap.Result = null,
};

/// Run one artifact command against `selected`. The selection may contain
/// more than one root; this function refuses with exit 2 naming the
/// candidates, exactly as the CLI's pre-dispatch guard does for the same
/// selection.
pub fn run(
    gpa: Allocator,
    store: *PngineSelection.Store,
    selected: *const PngineSelection.ProjectSelection,
    input_path: ?[]const u8,
    command: Command,
    config: Config,
) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const outcome = try runOutcome(alloc, store, selected, input_path, command, config);
    return .{
        .artifact = outcome.artifact,
        .diagnostics = outcome.diagnostics,
        .exit_code = outcome.exit_code,
        .original_size = outcome.original_size,
        .wasm_size = outcome.wasm_size,
        .source_map = outcome.source_map,
        ._arena = arena,
    };
}

fn runOutcome(
    alloc: Allocator,
    store: *PngineSelection.Store,
    selected: *const PngineSelection.ProjectSelection,
    input_path: ?[]const u8,
    command: Command,
    config: Config,
) !Outcome {
    var failure = PngineSelection.Failure{};
    const root = PngineSelection.requireSingleRoot(
        store,
        selected,
        input_path,
        &failure,
        alloc,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return usageFailure(alloc, failure.message),
    };

    const part = store.part(root) orelse return usageFailure(alloc, "the selected root no longer exists");
    if (part.kind != .shader_module) {
        return usageFailureWithFmt(
            alloc,
            "root '{s}' is a {s} root; reflect, minify, and compile require a shader-module root",
            .{ part.name, @tagName(part.kind) },
        );
    }

    const assembled = store.assembleRoot(root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return assemblyFailure(alloc, store, root, err),
    };

    // The existing pipelines take a sentinel-terminated source; the
    // assembled text is a plain owned slice.
    const source = try alloc.allocSentinel(u8, assembled.text.len, 0);
    @memcpy(source, assembled.text);

    return switch (command) {
        .reflect => reflect(alloc, store, root, assembled, source, config),
        .minify => minify(alloc, store, root, assembled, source, config),
        .compile => compile(alloc, store, root, assembled, source, config),
    };
}

fn reflect(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    assembled: *const pngine.Assembled,
    source: [:0]const u8,
    config: Config,
) !Outcome {
    const tokens = try wgslender.Lexer.tokenize(alloc, source);
    var parser = try wgslender.Parser.init(alloc, source, tokens);
    const maybe_module = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (maybe_module == null or parser.errors.items.len > 0) {
        return parseFailure(alloc, store, root, assembled, parser.errors.items);
    }

    const reflected = try wgslender.Reflect.reflect(alloc, maybe_module.?);
    var json: std.ArrayList(u8) = .empty;
    if (config.reflect_compact) {
        try reflected.toJsonVersion(&json, alloc, config.reflect_version);
    } else {
        try reflected.toJsonPrettyVersion(&json, alloc, config.reflect_version);
    }
    try json.append(alloc, '\n');

    return .{ .artifact = json.items };
}

fn minify(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    assembled: *const pngine.Assembled,
    source: [:0]const u8,
    config: Config,
) !Outcome {
    const result = try wgslender.minifyWithOptions(alloc, source, config.minify_options);
    if (result.errors.len > 0) {
        return parseFailure(alloc, store, root, assembled, result.errors);
    }

    var outcome = Outcome{ .artifact = result.code };
    if (result.source_map) |assembled_map| {
        const map_sources = try collectMapSources(alloc, store, assembled);
        const remapped = try SourceMaps.remap(
            alloc,
            assembled,
            map_sources,
            &assembled_map,
            .{
                .file = assembled_map.file,
                .include_sources_content = config.minify_options.source_map_options.include_source,
            },
        );
        outcome.source_map = remapped.map;
        if (remapped.dropped > 0) {
            outcome.diagnostics = try SourceMaps.warningLine(
                alloc,
                assembled.root_name,
                remapped.dropped,
            );
        }
    }
    return outcome;
}

/// Name every origin the assembled unit can reference. File parts use the
/// `:file` spelling exactly as the user wrote it; inline `:code` parts use
/// the stable virtual URI. Author text is copied into the artifact arena so
/// the map outlives the Store's own source buffers.
fn collectMapSources(
    alloc: Allocator,
    store: *PngineSelection.Store,
    assembled: *const pngine.Assembled,
) ![]SourceMaps.Source {
    var out: std.ArrayList(SourceMaps.Source) = .empty;
    errdefer out.deinit(alloc);

    for (assembled.segments) |segment| {
        const origin = segment.origin;
        var already = false;
        for (out.items) |existing| {
            if (existing.origin.program == origin.program and existing.origin.index == origin.index) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const part = store.part(origin) orelse continue;
        const program = store.program(origin.program) orelse continue;

        var text = store.textForPart(origin) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer text.deinit(store.gpa);
        const content = try alloc.dupe(u8, text.text);

        const name = switch (part.origin) {
            // The user's spelling, not the resolved path: a project's
            // `:file` is relative to its document and is what the editor
            // and the user call the file.
            .file => |file| try alloc.dupe(u8, file.path),
            .inline_code => try pngine.VirtualUri.encode(
                alloc,
                program.document_path,
                origin.index,
                pngine.Types.contentHash(content),
            ),
        };

        try out.append(alloc, .{
            .origin = origin,
            .name = name,
            .content = content,
        });
    }

    return out.toOwnedSlice(alloc);
}

fn compile(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    assembled: *const pngine.Assembled,
    source: [:0]const u8,
    config: Config,
) !Outcome {
    const result = try wgslender.compile(alloc, source, .{
        .minify = true,
        .minify_options = config.minify_options,
    });
    if (result.errors.len > 0) {
        return parseFailure(alloc, store, root, assembled, result.errors);
    }
    return .{
        .artifact = result.wasm,
        .original_size = result.original_size,
        .wasm_size = result.wasm_size,
    };
}

fn parseFailure(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    assembled: *const pngine.Assembled,
    errors: []const wgslender.Parser.ParseError,
) !Outcome {
    const diagnostics = try renderMappedErrors(alloc, store, root, assembled, errors);
    return .{ .diagnostics = diagnostics, .exit_code = 1 };
}

fn assemblyFailure(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    err: anyerror,
) !Outcome {
    var report = try pngine.Projection.Report.init(store.gpa, store, .{ .roots = &.{root} });
    defer report.deinit();
    try report.addAssemblyFailure(root, err);
    var finished = try report.finish();
    defer finished.deinit(store.gpa);

    const diagnostics = try renderItems(alloc, store, &report, root, finished.items);
    return .{ .diagnostics = diagnostics, .exit_code = 1 };
}

/// Map every parser error through the assembled-to-author segments and
/// render one `file:line:col: error: message [code]` line per entry.
fn renderMappedErrors(
    alloc: Allocator,
    store: *PngineSelection.Store,
    root: pngine.RootId,
    assembled: *const pngine.Assembled,
    errors: []const wgslender.Parser.ParseError,
) ![]u8 {
    var locator = try pngine.Projection.Report.init(store.gpa, store, .{ .roots = &.{root} });
    defer locator.deinit();

    var out: std.ArrayList(u8) = .empty;
    for (errors) |err| {
        var entry = Diagnostic.Entry{
            .severity = .@"error",
            .message = err.message,
            .code = err.code,
        };

        const mapped = assembled.offsetToOrigin(err.pos);
        const location = try locate(alloc, store, &locator, root, mapped);
        entry.range = .{
            .start = .{ .offset = location.offset, .line = location.line, .column = location.column },
            .end = .{ .offset = location.offset, .line = location.line, .column = location.column },
        };
        try Diagnostic.writeTextLine(&out, alloc, &entry, location.prefix);
    }
    return out.toOwnedSlice(alloc);
}

fn renderItems(
    alloc: Allocator,
    store: *PngineSelection.Store,
    report: *pngine.Projection.Report,
    root: pngine.RootId,
    items: []const pngine.Projection.DiagnosticOut,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items) |item| {
        var entry = Diagnostic.Entry{
            .severity = item.severity,
            .code = item.code,
            .message = item.message,
            .spec_ref = item.spec_ref,
            .source = item.source,
            .data = item.data,
        };

        if (item.origin) |origin| {
            const offset = item.range.start;
            const mapped = pngine.OriginOffset{ .origin = origin, .offset = offset };
            const location = try locate(alloc, store, report, root, mapped);
            entry.range = .{
                .start = .{ .offset = location.offset, .line = location.line, .column = location.column },
                .end = .{ .offset = location.offset, .line = location.line, .column = location.column },
            };
            try Diagnostic.writeTextLine(&out, alloc, &entry, location.prefix);
        } else {
            const prefix = report.projectPath(item.program orelse root.program) orelse "<unknown>";
            entry.range = .{
                .start = .{ .offset = 0, .line = 1, .column = 1 },
                .end = .{ .offset = 0, .line = 1, .column = 1 },
            };
            try Diagnostic.writeTextLine(&out, alloc, &entry, prefix);
        }
    }
    return out.toOwnedSlice(alloc);
}

const Location = struct {
    prefix: []const u8,
    /// Author-local byte offset. Never an assembled offset: the entry is
    /// rendered against `prefix`.
    offset: u32,
    line: u32,
    column: u32,
};

/// Resolve one author position. File origins use the shared projector's
/// author document index; inline `:code` parts have no file URI, so they
/// use a stable `<inline:name>` label and their own author text. A project
/// fallback (no origin) is line 1 of the `.sjon` document.
fn locate(
    alloc: Allocator,
    store: *PngineSelection.Store,
    report: *pngine.Projection.Report,
    root: pngine.RootId,
    mapped: ?pngine.OriginOffset,
) !Location {
    const origin_offset = mapped orelse return .{
        .prefix = report.projectPath(root.program) orelse "<unknown>",
        .offset = 0,
        .line = 1,
        .column = 1,
    };
    const origin = origin_offset.origin;

    if (report.originPath(origin)) |path| {
        const position = report.originPosition(origin, origin_offset.offset) orelse
            pngine.Projection.Position{ .line = 1, .column = 1 };
        return .{
            .prefix = path,
            .offset = origin_offset.offset,
            .line = position.line,
            .column = position.column,
        };
    }

    const part = store.part(origin) orelse return .{
        .prefix = "<unknown>",
        .offset = 0,
        .line = 1,
        .column = 1,
    };
    const prefix = try std.fmt.allocPrint(alloc, "<inline:{s}>", .{part.name});

    var text = store.textForPart(origin) catch return .{
        .prefix = prefix,
        .offset = 0,
        .line = 1,
        .column = 1,
    };
    defer text.deinit(store.gpa);

    var line_index = try Diagnostic.LineIndex.init(alloc, text.text);
    defer line_index.deinit(alloc);
    const lc = line_index.byteOffsetToLineColumn(origin_offset.offset);
    return .{
        .prefix = prefix,
        .offset = origin_offset.offset,
        .line = lc.line + 1,
        .column = lc.col + 1,
    };
}

fn usageFailure(alloc: Allocator, message: []const u8) !Outcome {
    return usageFailureWithFmt(alloc, "{s}", .{message});
}

fn usageFailureWithFmt(
    alloc: Allocator,
    comptime format: []const u8,
    args: anytype,
) !Outcome {
    const body = try std.fmt.allocPrint(alloc, format, args);
    const diagnostics = try std.fmt.allocPrint(alloc, "error: {s}\n", .{body});
    return .{ .diagnostics = diagnostics, .exit_code = 2 };
}
