//! Pipeline — composable WGSL processing passes.
//!
//! The Minifier's hardcoded sequence is now a default `Pass` list that
//! `minifyCore` builds and feeds to `Pipeline.run`. Custom callers can
//! mix-and-match passes, omit those they don't need, or inject
//! `Pass.custom` for arbitrary work between bundled passes.
//!
//! Passes communicate exclusively through `State`. Each pass declares
//! the fields it produces in the doc comment of its `Pass` variant.
//! Passes that depend on a missing input become silent no-ops — the
//! Pipeline does not enforce ordering.
//!
//! Standard order (built by `Minifier.minifyCore`):
//!   tokenize → parse → mark_api_facing → dce → compute_usage →
//!   build_reserved_names → init_source_map → print → finalize_source_map
//!
//! Stability: `Pass` enum variants and bundled-pass field contracts are
//! stable. `State` field additions are non-breaking (new fields default
//! to `null`); field removals are breaking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const RenamerMod = @import("Renamer.zig");
const Dce = @import("Dce.zig");
const Liveness = @import("Liveness.zig");
const RenamePolicy = @import("RenamePolicy.zig");
const SourceMap = @import("SourceMap.zig");
const Minifier = @import("Minifier.zig");

const Pipeline = @This();

/// A single pipeline pass. Bundled passes have fixed produces/consumes
/// contracts (see field doc comments on `State`); `custom` is the
/// extension point for downstream tooling.
pub const Pass = union(enum) {
    /// Produces `state.tokens`.
    tokenize,
    /// Consumes `state.tokens`. Produces `state.module` on success or
    /// `state.errors` on failure (subsequent module-dependent passes
    /// silently skip when `state.module == null`).
    parse,
    /// Consumes `state.module`. Produces `state.rename_policy`.
    mark_api_facing,
    /// Consumes `state.module`. Produces `module.liveness` and
    /// `state.symbols_dead`.
    dce,
    /// Consumes `state.module`. Produces `state.usage`.
    compute_usage,
    /// Produces `state.reserved`.
    build_reserved_names,
    /// Produces `state.source_map_gen` when `options.generate_source_map`
    /// is set; otherwise no-op.
    init_source_map,
    /// Consumes `state.module`, `state.rename_policy`, `state.reserved`,
    /// optionally `state.usage` (frequency renamer) and
    /// `state.source_map_gen`. Produces `state.renamer` and
    /// `state.output`.
    print,
    /// Consumes `state.source_map_gen`. Produces `state.source_map`.
    finalize_source_map,
    /// Escape hatch. Receives mutable `*State` for read/write access and
    /// `*const Options` for read-only configuration. Allocations should
    /// use `state.arena`.
    custom: *const fn (state: *State, options: *const Minifier.Options) Allocator.Error!void,
};

/// Pipeline state. Each `?T` field is populated by the pass that
/// produces it; downstream passes that read a missing input no-op.
pub const State = struct {
    arena: Allocator,
    source: [:0]const u8,

    /// Set by `tokenize`; consumed by `parse`. Lives in `arena`.
    tokens: ?std.MultiArrayList(Lexer.Token) = null,

    /// Set by `parse` on success, or pre-populated via `initWithModule`.
    /// Null = no module available; module-dependent passes skip.
    module: ?*Ast.Module = null,

    /// Set by `parse` to the parser's error list when parsing fails.
    /// Module-dependent passes skip when this is non-empty.
    errors: []const Parser.ParseError = &.{},

    /// Set by `mark_api_facing`. Boxed so the renamer (built by `print`)
    /// can hold a pointer that outlives the pass returning the policy.
    rename_policy: ?*RenamePolicy = null,

    /// Set by `dce` to the per-pipeline dead symbol count. Liveness
    /// itself lives on `module.liveness`.
    symbols_dead: u32 = 0,

    /// Set by `compute_usage`. Per-symbol usage frequencies fed to the
    /// renamer's accumulator in the `print` pass.
    usage: ?std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) = null,

    /// Set by `build_reserved_names`. Names the renamer cannot assign.
    reserved: ?std.StringHashMapUnmanaged(void) = null,

    /// Set by `init_source_map` when `options.generate_source_map` is on.
    source_map_gen: ?*SourceMap.Generator = null,

    /// Set by `print`. Retained so reflection callers can query renamed
    /// symbol names after the pipeline completes.
    renamer: ?*const Printer.Renamer = null,

    /// Set by `print`. The minified text.
    output: ?[]const u8 = null,

    /// Set by `finalize_source_map`. Null when no source map requested.
    source_map: ?SourceMap.Result = null,

    pub fn init(arena: Allocator, source: [:0]const u8) State {
        return .{ .arena = arena, .source = source };
    }

    /// Pre-populated state for callers that already have a parsed module
    /// (e.g. Compiler reusing analysis). Skip `tokenize` + `parse` in
    /// the pass list when using this constructor.
    pub fn initWithModule(arena: Allocator, source: [:0]const u8, module: *Ast.Module) State {
        return .{ .arena = arena, .source = source, .module = module };
    }
};

/// Run `passes` over `state` in order. Each pass mutates `state` in
/// place. `options` is passed to every pass, including `Pass.custom`.
///
/// The pipeline is intentionally non-strict: passes check their own
/// preconditions and silently skip when their inputs aren't set.
pub fn run(state: *State, passes: []const Pass, options: Minifier.Options) Allocator.Error!void {
    for (passes) |pass| {
        switch (pass) {
            .tokenize => try runTokenize(state),
            .parse => try runParse(state),
            .mark_api_facing => try runMarkApiFacing(state, options),
            .dce => try runDce(state, options),
            .compute_usage => try runComputeUsage(state),
            .build_reserved_names => try runBuildReservedNames(state, options),
            .init_source_map => try runInitSourceMap(state, options),
            .print => try runPrint(state, options),
            .finalize_source_map => try runFinalizeSourceMap(state),
            .custom => |f| try f(state, &options),
        }
    }
}

fn runTokenize(state: *State) Allocator.Error!void {
    state.tokens = try Lexer.tokenize(state.arena, state.source);
}

fn runParse(state: *State) Allocator.Error!void {
    const tokens = state.tokens orelse return;
    var parser = try Parser.init(state.arena, state.source, tokens);
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            state.errors = parser.errors.items;
            return;
        },
    };
    if (parser.errors.items.len > 0) {
        state.errors = parser.errors.items;
        return;
    }
    state.module = module;
}

fn runMarkApiFacing(state: *State, options: Minifier.Options) Allocator.Error!void {
    const module = state.module orelse return;
    var builder = try RenamePolicy.Builder.init(state.arena, module.symbols.items.len);
    builder.markEntryPoints(module);
    builder.markBuiltinsAndOverrides(module);
    if (!options.mangle_external_bindings) builder.markExternalBindings(module);
    builder.markKeepNames(module, options.keep_names);
    if (options.preserve_uniform_struct_types) builder.markUniformStructTypes(module);
    const policy_box = try state.arena.create(RenamePolicy);
    policy_box.* = builder.build();
    state.rename_policy = policy_box;
}

fn runDce(state: *State, options: Minifier.Options) Allocator.Error!void {
    const module = state.module orelse return;
    module.liveness = try Liveness.init(state.arena, module.symbols.items.len);
    if (options.tree_shaking) {
        state.symbols_dead = try Dce.mark(state.arena, module, &module.liveness);
        std.debug.assert(state.symbols_dead <= module.symbols.items.len);
    } else {
        module.liveness.markAllLive();
    }
}

fn runComputeUsage(state: *State) Allocator.Error!void {
    const module = state.module orelse return;
    state.usage = try Minifier.computeSymbolUsage(state.arena, module);
}

fn runBuildReservedNames(state: *State, options: Minifier.Options) Allocator.Error!void {
    var reserved = try RenamerMod.computeReservedNames(state.arena);
    for (options.keep_names) |name| {
        try reserved.put(state.arena, name, {});
    }
    state.reserved = reserved;
}

fn runInitSourceMap(state: *State, options: Minifier.Options) Allocator.Error!void {
    if (!options.generate_source_map) return;
    const gen = try state.arena.create(SourceMap.Generator);
    gen.* = try SourceMap.Generator.init(state.arena, state.source);
    gen.setFile(options.source_map_options.file);
    gen.setSourceName(options.source_map_options.source_name);
    gen.setIncludeSource(options.source_map_options.include_source);
    state.source_map_gen = gen;
}

fn runPrint(state: *State, options: Minifier.Options) Allocator.Error!void {
    const module = state.module orelse return;
    const policy = state.rename_policy orelse return;
    const reserved = state.reserved orelse return;

    const renamer_base = if (options.minify_identifiers) blk: {
        // Frequency-based renamer requires the usage table.
        if (state.usage == null) return;
        const r = try state.arena.create(RenamerMod.MinifyRenamer);
        r.* = RenamerMod.MinifyRenamer.init(state.arena, module.symbols.items, reserved);
        r.setSideTables(&module.use_counts, policy);
        r.accumulateSymbolUseCounts(&state.usage.?);
        try r.allocateSlots();
        try r.reserveUnrenamedSymbolNames();
        try r.assignNames();
        r.renamer.ptr = @ptrCast(r);
        break :blk &r.renamer;
    } else blk: {
        const r = try state.arena.create(RenamerMod.NoOpRenamer);
        r.* = RenamerMod.NoOpRenamer.init(module.symbols.items);
        r.renamer.ptr = @ptrCast(r);
        break :blk &r.renamer;
    };

    var renamer: *const Printer.Renamer = renamer_base;
    if (options.scope_local_rename and options.minify_identifiers) {
        const scope = try Minifier.ScopeLocalRenamer.init(state.arena, module, renamer, policy);
        renamer = &scope.ren;
    }
    state.renamer = renamer;

    var printer = Printer.init(state.arena, .{
        .minify_whitespace = options.minify_whitespace,
        .minify_identifiers = options.minify_identifiers,
        .minify_syntax = options.minify_syntax,
        .tree_shaking = if (options.sort_declarations) false else options.tree_shaking,
        .renamer = renamer,
        .source_map_gen = state.source_map_gen,
    }, module.symbols.items);

    if (options.sort_declarations) {
        const sorted = try Minifier.sortDeclarations(state.arena, module);
        printer.buf.clearRetainingCapacity();
        for (sorted) |decl| {
            try printer.printDecl(decl);
        }
        state.output = printer.buf.items;
        return;
    }

    state.output = try printer.print(module);
}

fn runFinalizeSourceMap(state: *State) Allocator.Error!void {
    const gen = state.source_map_gen orelse return;
    state.source_map = try gen.generate();
}

// =========================================================================
// Tests
// =========================================================================

test "pipeline: smoke test runs the default pass list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 = "fn main() { let x = 1; }";

    var state = State.init(a, source);
    try Pipeline.run(&state, &.{
        .tokenize, .parse, .mark_api_facing, .dce, .compute_usage,
        .build_reserved_names, .init_source_map, .print, .finalize_source_map,
    }, .{});

    try std.testing.expect(state.module != null);
    try std.testing.expect(state.errors.len == 0);
    try std.testing.expect(state.output != null);
    try std.testing.expect(state.output.?.len > 0);
}

test "pipeline: parse error short-circuits subsequent passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 = "fn { invalid }";

    var state = State.init(a, source);
    try Pipeline.run(&state, &.{
        .tokenize, .parse, .mark_api_facing, .dce, .compute_usage,
        .build_reserved_names, .print,
    }, .{});

    try std.testing.expect(state.errors.len > 0);
    try std.testing.expect(state.module == null);
    try std.testing.expect(state.output == null);
}
