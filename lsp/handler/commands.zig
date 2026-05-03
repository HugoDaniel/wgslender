//! workspace/executeCommand handlers: dispatch the void-returning
//! mode-toggle commands and the data-returning
//! `wgslender.showMinifiedOutput` / `wgslender/reflect` operations.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const MinifySettings = wgslender.MinifySettings;

pub const CommandError = error{
    UnknownCommand,
    InvalidParams,
    DocumentNotFound,
    OutOfMemory,
    MinifyFailed,
    ReflectFailed,
};

/// Result of running `wgslender.showMinifiedOutput`. Mirrors master-plan
/// §9.2: the client opens a virtual document with `minified_text` and
/// uses the byte counts for status-bar / lens display without
/// re-deriving them. All four fields are owned by the request arena
/// passed into `runShowMinifiedOutput`; the caller serialises them and
/// the arena's `deinit` releases everything.
pub const MinifyCommandResult = struct {
    uri: []const u8,
    minified_text: []const u8,
    byte_count: u32,
    gz_count: u32,
};

/// Result of `wgslender/reflect` (custom LSP request). The shared handler
/// reflects the analyzed module and serialises the JSON itself so neither
/// transport (native NativeServer / WASM lsp) needs to know the schema.
/// All slices are owned by the request arena passed to `runReflect`.
pub const ReflectCommandResult = struct {
    uri: []const u8,
    /// Compact JSON output (use `prettyPrint = true` to format).
    json: []const u8,
    version: wgslender.Reflect.JsonVersion,
};

/// Dispatch a `workspace/executeCommand` request. `args` matches the LSP
/// `ExecuteCommandParams.arguments` shape: `null` when the client sent no
/// arguments, otherwise a slice of `LSPAny` (= `std.json.Value`).
///
/// Used for the void-returning commands (mode toggles). Data-returning
/// commands (e.g. `wgslender.showMinifiedOutput`) live on dedicated
/// methods because the wire shape — and the arena lifetime — differs.
pub fn executeCommand(handler: *Handler, name: []const u8, args: ?[]const std.json.Value) CommandError!void {
    if (std.mem.eql(u8, name, "wgslender.setMinifyMode")) {
        const items = args orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const s = switch (items[0]) {
            .string => |x| x,
            else => return error.InvalidParams,
        };
        const m = MinifySettings.Mode.fromString(s) orelse return error.InvalidParams;
        handler.workspace_config.lsp_minify.mode = m;
        return;
    }
    if (std.mem.eql(u8, name, "wgslender.toggleMinifyMode")) {
        const current = handler.effectiveMinify().mode;
        const next: MinifySettings.Mode = switch (current) {
            .off => .insights,
            .insights => .strict,
            .strict => .off,
        };
        handler.workspace_config.lsp_minify.mode = next;
        return;
    }
    if (std.mem.eql(u8, name, "wgslender.recomputeMinifyInsights")) {
        // Phase 7 native debounce shim. lsp-kit's `basic_server.run`
        // dispatch only knows method names registered with the
        // generator, so a custom `wgslender/recomputeMinifyInsights`
        // notification can't be routed by the native transport. We
        // expose the same operation as a command instead — clients
        // send `workspace/executeCommand` with `[uri]` as the only
        // argument. The WASM transport keeps the notification name
        // (raw dispatch matches strings directly) and converges on
        // `Handler.refreshMinifyInsights`.
        const items = args orelse return error.InvalidParams;
        if (items.len < 1) return error.InvalidParams;
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        handler.refreshMinifyInsights(uri);
        return;
    }
    return error.UnknownCommand;
}

/// Run `wgslender.showMinifiedOutput` for `uri`. The full minifier
/// pipeline runs against the document's current source — this is the
/// "cold path" the master plan §2.4 reserves for on-command requests
/// (the lens title itself uses the cheap `MinifyEstimator`). All
/// returned slices are owned by `arena`; the caller's request arena is
/// the right home because the bridge layer serialises the result and
/// tears the arena down right after.
///
/// `byte_count` / `gz_count` come from a parallel `MinifyEstimator`
/// pass so the JSON response carries the same numbers the lens title
/// already showed. Using estimator output here (rather than
/// `result.minified_size`) keeps the lens / response numbers in
/// lockstep — the estimator is the authoritative source for in-LSP
/// size hints.
pub fn runShowMinifiedOutput(
    handler: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
) CommandError!MinifyCommandResult {
    const doc = handler.documents.getPtr(uri) orelse return error.DocumentNotFound;
    const eff = handler.effectiveMinifyFor(uri);

    // Minifier.minify wants sentinel-terminated source.
    const source = try arena.dupeZ(u8, doc.source);

    const result = wgslender.Minifier.minify(arena, source, .{
        .mangle_external_bindings = eff.mangle_external_bindings,
    }) catch return error.MinifyFailed;

    // Estimator runs against the analysis module so byte_count matches
    // what the code lens displayed. It mutates `is_live`, so a scratch
    // arena keeps the side-effects scoped to this call.
    var est_arena = std.heap.ArenaAllocator.init(handler.gpa);
    defer est_arena.deinit();

    const analysis = handler.analyzeDocument(uri) catch return error.MinifyFailed;
    const module = analysis.module orelse return error.MinifyFailed;

    const est = wgslender.MinifyEstimator.estimate(
        est_arena.allocator(),
        @constCast(module),
        .{ .mangle_external_bindings = eff.mangle_external_bindings },
    ) catch return error.MinifyFailed;

    return .{
        .uri = try arena.dupe(u8, uri),
        .minified_text = result.code,
        .byte_count = est.total_min,
        .gz_count = est.total_gz,
    };
}

/// Reflect the document and serialise the result to JSON at the requested
/// schema version. Reuses the cached analysis module (so a hot doc skips
/// re-tokenize + re-parse) and serialises into the caller's arena.
pub fn runReflect(
    handler: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
    version: wgslender.Reflect.JsonVersion,
    pretty: bool,
) CommandError!ReflectCommandResult {
    if (handler.documents.getPtr(uri) == null) return error.DocumentNotFound;

    const analysis = handler.analyzeDocument(uri) catch return error.ReflectFailed;
    const module = analysis.module orelse return error.ReflectFailed;

    var result = wgslender.Reflect.reflect(arena, @constCast(module)) catch
        return error.ReflectFailed;
    // `reflect()` allocates from `arena`; no internal arena to drain.
    _ = &result;

    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (pretty) {
        result.toJsonPrettyVersion(&json_buf, arena, version) catch return error.OutOfMemory;
    } else {
        result.toJsonVersion(&json_buf, arena, version) catch return error.OutOfMemory;
    }

    return .{
        .uri = try arena.dupe(u8, uri),
        .json = json_buf.items,
        .version = version,
    };
}
