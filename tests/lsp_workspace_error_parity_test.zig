//! Error-envelope parity for the workspace command surface. The two
//! transports take divergent code paths when commands fail:
//!
//!   - Native (`lsp/native/workspace_commands.zig::handle()`): returns a
//!     Zig error → lsp-kit's `src/basic_server.zig` maps it to a
//!     `JsonRPCMessage.Response.Error.Code` and writes
//!     `{"code":<n>,"message":"<@errorName(err)>"}` via
//!     `lsp.writeErrorResponse` with `emit_null_optional_fields = false`.
//!   - WASM (`lsp/wasm/workspace_commands.zig`): calls
//!     `sendErrorCode(id, <code>, <message>)` which manually emits
//!     `{"code":<n>,"message":"<hardcoded english>"}`.
//!
//! Two things drift independently here:
//!   1. The numeric `code` (must stay in sync — the parity contract).
//!   2. The `message` strings (intentionally divergent — `@errorName` vs
//!      hardcoded English — but each side is locked to its expected shape
//!      so a future tweak fails the test on purpose).
//!
//! Out of scope:
//!   - `MinifyFailed` / `ReflectFailed` (-32603) require a
//!     malformed-but-parseable WGSL fixture; not worth the setup for a
//!     single code mapping.
//!   - `wasm/handleReflect` silently ignores a non-bool `pretty` whereas
//!     the native side returns `InvalidParams` — that is a real transport
//!     divergence and is not testable as parity.
//!
//! The wasm `handleReflect` is reached via the custom `wgslender/reflect`
//! method (not `workspace/executeCommand`), so the reflect-error cases
//! drive that handler directly while the native side stays on
//! `executeCommand`. The asserted invariant is that equivalent failure
//! conditions produce the same numeric code on both transports.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const helpers = @import("lsp_parity_helpers.zig");
const native_workspace_commands = @import("native_workspace_commands");
const wasm_workspace_commands = @import("wasm_workspace_commands");

/// `wasm_workspace_commands.Ctx.lifecycleCtx` is a sibling-file import
/// inside the wasm module. We can't separately `@import("wasm_lifecycle")`
/// — that would compile a *different* instance of `lifecycle.zig` with a
/// distinct type identity. Instead, infer the field type from the parent
/// struct so the lifecycle Ctx we build is the exact type the wasm Ctx
/// expects.
const WasmLifecycleCtx = std.meta.fieldInfo(wasm_workspace_commands.Ctx, .lifecycleCtx).type;

// =========================================================================
// Native error → JsonRPC code mapping
//
// Mirrors the parallel-array switch in `basic_server.zig:111-141`. Only
// the codes the workspace adapter actually returns are listed; anything
// else is a test-side bug, not silently swallowed.
// =========================================================================

fn nativeErrorToCode(err: anyerror) lsp.JsonRPCMessage.Response.Error.Code {
    return switch (err) {
        error.MethodNotFound => .method_not_found,
        error.InvalidParams => .invalid_params,
        error.InternalError => .internal_error,
        else => @panic("unexpected error returned from native handle()"),
    };
}

// =========================================================================
// WASM Ctx wiring — captures sendErrorCode (id, code, message) into a
// module-level slot. `zig test` runs tests sequentially within a file,
// so a single static slot is safe; each `runWasm*` resets it first.
// =========================================================================

const Captured = struct {
    code: i32 = 0,
    message: []const u8 = "",
    fired: bool = false,
};

var captured: Captured = .{};

fn captureSendErrorCode(_: ?std.json.Value, code: i32, message: []const u8) void {
    captured = .{ .code = code, .message = message, .fired = true };
}

fn unreachableSendResult(_: ?std.json.Value, _: []const u8) void {
    @panic("error path should not invoke sendResult");
}

fn resetCaptured() void {
    captured = .{};
}

const WasmHarness = struct {
    handler: *Handler,
    ctx: wasm_workspace_commands.Ctx,
    // These fields are storage for pointers held by the lifecycle Ctx;
    // `republishAllDocuments` only fires on success branches so they
    // are inert for error tests, but Zig still requires real targets.
    client_supports_config: bool,
    next_request_id: i64,
    pending_config_id: ?i64,
    outbox: std.ArrayListUnmanaged([]u8),
};

fn makeWasmHarness(handler: *Handler) WasmHarness {
    return .{
        .handler = handler,
        .ctx = undefined,
        .client_supports_config = false,
        .next_request_id = 0,
        .pending_config_id = null,
        .outbox = .empty,
    };
}

fn wireWasmCtx(h: *WasmHarness) void {
    const lc: WasmLifecycleCtx = .{
        .gpa = std.testing.allocator,
        .handler = h.handler,
        .outbox = &h.outbox,
        .client_supports_configuration = &h.client_supports_config,
        .next_request_id = &h.next_request_id,
        .pending_config_id = &h.pending_config_id,
        .sendResult = unreachableSendResult,
    };
    h.ctx = .{
        .gpa = std.testing.allocator,
        .handler = h.handler,
        .outbox = &h.outbox,
        .sendResult = unreachableSendResult,
        .sendErrorCode = captureSendErrorCode,
        .lifecycleCtx = lc,
    };
}

// =========================================================================
// Drivers
//
// Each test:
//   1. Builds a fresh Handler.
//   2. Drives native handle() with a `Params` struct, captures the Zig error.
//   3. Drives wasm handle*() with a parsed JSON root, captures
//      (code, message) via the static slot.
//   4. Encodes both into JSON envelopes via the helpers module.
//   5. Asserts code parity + each transport's message lock-in.
// =========================================================================

const FailureCase = struct {
    /// Free-text label for diagnostics on failure.
    label: []const u8,
    /// Expected wasm-side hardcoded message (what `sendErrorCode` will
    /// pass through). Locked exactly so any rewording fails this test.
    wasm_message: []const u8,
};

fn assertParity(
    arena: std.mem.Allocator,
    case: FailureCase,
    native_err: anyerror,
) !void {
    if (!captured.fired) {
        std.debug.print("\n[{s}] wasm captured.fired = false (sendErrorCode never called)\n", .{case.label});
        return error.WasmDidNotFire;
    }

    const native_code = nativeErrorToCode(native_err);
    const native_env = try helpers.writeAndParseErrorEnvelope(arena, native_code, @errorName(native_err));
    const wasm_env = try helpers.buildAndParseWasmErrorEnvelope(arena, captured.code, captured.message);

    try helpers.expectEqualErrorCode(native_env, wasm_env);

    // Lock native message: must match `@errorName(native_err)` exactly.
    try std.testing.expectEqualStrings(@errorName(native_err), native_env.object.get("message").?.string);
    // Lock wasm message: must match the hardcoded string from the case.
    try std.testing.expectEqualStrings(case.wasm_message, wasm_env.object.get("message").?.string);
}

fn parseRoot(arena: std.mem.Allocator, json_text: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
    return parsed.object;
}

// =========================================================================
// showMinifiedOutput error cases (both transports via executeCommand)
// =========================================================================

test "parity: showMinifiedOutput — arguments: null → InvalidParams / -32602 / 'missing uri'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    // Native: arguments = null
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.showMinifiedOutput",
        .arguments = null,
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    // Wasm: arguments key absent (equivalent to null)
    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    var ws_outbox = std.ArrayListUnmanaged([]u8).empty;
    defer ws_outbox.deinit(std.testing.allocator);
    const root = try parseRoot(aa,
        \\{"params":{"command":"wgslender.server.showMinifiedOutput"}}
    );
    wasm_workspace_commands.handleExecuteCommand(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "showMinifiedOutput / null args",
        .wasm_message = "missing uri",
    }, native_err);
}

test "parity: showMinifiedOutput — arguments: [] → InvalidParams / -32602 / 'missing uri'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const empty_args: []const std.json.Value = &.{};
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.showMinifiedOutput",
        .arguments = empty_args,
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"command":"wgslender.server.showMinifiedOutput","arguments":[]}}
    );
    wasm_workspace_commands.handleExecuteCommand(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "showMinifiedOutput / empty args",
        .wasm_message = "missing uri",
    }, native_err);
}

test "parity: showMinifiedOutput — arguments[0] not a string → InvalidParams / -32602 / 'uri must be a string'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    var args = [_]std.json.Value{.{ .integer = 42 }};
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.showMinifiedOutput",
        .arguments = args[0..],
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"command":"wgslender.server.showMinifiedOutput","arguments":[42]}}
    );
    wasm_workspace_commands.handleExecuteCommand(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "showMinifiedOutput / non-string uri",
        .wasm_message = "uri must be a string",
    }, native_err);
}

test "parity: showMinifiedOutput — unknown URI → InvalidParams / -32602 / 'document not found'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    var args = [_]std.json.Value{.{ .string = "test://unknown.wgsl" }};
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.showMinifiedOutput",
        .arguments = args[0..],
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"command":"wgslender.server.showMinifiedOutput","arguments":["test://unknown.wgsl"]}}
    );
    wasm_workspace_commands.handleExecuteCommand(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "showMinifiedOutput / unknown uri",
        .wasm_message = "document not found",
    }, native_err);
}

// =========================================================================
// reflect error cases
//
// Native: dispatches via `executeCommand` with command="wgslender.server.reflect".
// Wasm: dispatches via the custom `wgslender/reflect` method, so we drive
// `handleReflect` directly with a different params shape. The asserted
// invariant is that the same logical failure produces the same code on
// both transports — message strings are locked separately per side.
// =========================================================================

test "parity: reflect — missing params → InvalidParams / -32602 / 'missing params'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    // Native equivalent: arguments: null → runReflect → InvalidParams
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.reflect",
        .arguments = null,
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    // Wasm equivalent: no `params` field at all → "missing params"
    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"method":"wgslender/reflect"}
    );
    wasm_workspace_commands.handleReflect(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "reflect / missing params",
        .wasm_message = "missing params",
    }, native_err);
}

test "parity: reflect — bad format string 'v3' → InvalidParams / -32602 / format-not-allowed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    var args = [_]std.json.Value{
        .{ .string = "test://any.wgsl" },
        .{ .string = "v3" },
    };
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.reflect",
        .arguments = args[0..],
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"textDocument":{"uri":"test://any.wgsl"},"format":"v3"}}
    );
    wasm_workspace_commands.handleReflect(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "reflect / bad format",
        .wasm_message = "format must be 'v1' or 'v2'",
    }, native_err);
}

test "parity: reflect — unknown URI → InvalidParams / -32602 / 'document not found'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    var args = [_]std.json.Value{
        .{ .string = "test://unknown.wgsl" },
        .{ .string = "v2" },
    };
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.server.reflect",
        .arguments = args[0..],
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"textDocument":{"uri":"test://unknown.wgsl"},"format":"v2"}}
    );
    wasm_workspace_commands.handleReflect(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "reflect / unknown uri",
        .wasm_message = "document not found",
    }, native_err);
}

// =========================================================================
// Unknown command (both transports via executeCommand)
// =========================================================================

test "parity: executeCommand unknown name → MethodNotFound / -32601 / 'unknown command'" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const empty_args: []const std.json.Value = &.{};
    const params: lsp.types.workspace.execute_command.Params = .{
        .command = "wgslender.notACommand",
        .arguments = empty_args,
    };
    const native_err = if (native_workspace_commands.handle(handler, aa, params)) |_|
        @panic("expected error from native handle()")
    else |e|
        e;

    resetCaptured();
    var harness = makeWasmHarness(handler);
    wireWasmCtx(&harness);
    const root = try parseRoot(aa,
        \\{"params":{"command":"wgslender.notACommand","arguments":[]}}
    );
    wasm_workspace_commands.handleExecuteCommand(harness.ctx, root, .{ .integer = 0 });

    try assertParity(aa, .{
        .label = "executeCommand / unknown name",
        .wasm_message = "unknown command",
    }, native_err);
}
