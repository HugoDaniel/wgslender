//! WGSL Language Server — native entry point.
//!
//! Runs the LSP server over stdio using lsp-kit's basic_server framework.
//! All WGSL-specific dispatch lives in `NativeServer` (this file just
//! wires transport + spawns the idle-debounce timer thread).
//!
//! The stdio transport is wrapped in `lsp.ThreadSafeTransport` because
//! Phase 7 added a second writer (the timer thread that publishes
//! `textDocument/publishDiagnostics` after the debounce window settles).
//! Without the wrapper concurrent writes from {basic_server callback
//! thread, timer thread} would interleave bytes on stdout.

const std = @import("std");
const lsp = @import("lsp");
const NativeServer = @import("NativeServer");

pub fn main(init: std.process.Init) !void {
    // `basic_server.run` instantiates `MessageType(NativeServer)`, which folds
    // every request/notification handler on `NativeServer` into two comptime
    // tagged unions. Our handler surface is large enough to exhaust the
    // default branch quota, and the quota is a property of this comptime
    // evaluation — raising it here covers the nested instantiation, so
    // lsp-kit stays an unpatched upstream dependency.
    @setEvalBranchQuota(20_000);

    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    // Read happens only on the basic_server thread, so `thread_safe_read`
    // can stay off; only writes need serialisation.
    var safe_transport: lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .init(&stdio_transport.transport);

    var server: NativeServer = .init(init.gpa, &safe_transport.transport, init.io);
    defer server.deinit();

    // lsp-kit's typed request union has no seat for a project-defined custom
    // method. Intercept `wgslender/pnginePart` between the wire and
    // `basic_server`; every other message is passed through unchanged.
    var pngine_transport: PnginePartTransport = .init(&safe_transport.transport, &server);
    server.transport = &pngine_transport.transport;

    try server.start();

    try lsp.basic_server.run(init.io, init.gpa, server.transport, &server, std.log.err);
}

/// Wire-level interception for the native-only `wgslender/pnginePart`
/// request. `basic_server` answers unknown methods with a null result, which
/// a virtual-document provider must never see as content, so the request is
/// answered here before the typed dispatcher.
const PnginePartTransport = struct {
    transport: lsp.Transport,
    child: *lsp.Transport,
    server: *NativeServer,

    const method = "wgslender/pnginePart";

    fn init(child: *lsp.Transport, server: *NativeServer) PnginePartTransport {
        return .{
            .transport = .{
                .vtable = &.{
                    .readJsonMessage = readJsonMessage,
                    .writeJsonMessage = writeJsonMessage,
                },
            },
            .child = child,
            .server = server,
        };
    }

    fn readJsonMessage(
        transport: *lsp.Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        const self: *PnginePartTransport = @fieldParentPtr("transport", transport);
        while (true) {
            const message = try self.child.readJsonMessage(io, allocator);
            const handled = handleCustomRequest(self, io, allocator, message) catch |err| switch (err) {
                error.OutOfMemory => {
                    allocator.free(message);
                    return error.OutOfMemory;
                },
                else => false,
            };
            if (handled) {
                allocator.free(message);
                continue;
            }
            return message;
        }
    }

    fn writeJsonMessage(
        transport: *lsp.Transport,
        io: std.Io,
        json_message: []const u8,
    ) lsp.Transport.WriteError!void {
        const self: *PnginePartTransport = @fieldParentPtr("transport", transport);
        return self.child.writeJsonMessage(io, json_message);
    }

    /// Return true when `message` was a `wgslender/pnginePart` request and
    /// has been answered. Parse failures and other methods pass through to
    /// the normal dispatcher.
    fn handleCustomRequest(
        self: *PnginePartTransport,
        io: std.Io,
        allocator: std.mem.Allocator,
        message: []const u8,
    ) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{
            .ignore_unknown_fields = true,
            .max_value_len = null,
        }) catch return false;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return false,
        };
        const method_value = root.get("method") orelse return false;
        if (method_value != .string) return false;
        if (!std.mem.eql(u8, method_value.string, method)) return false;

        const id_value = root.get("id") orelse return false;
        const id: lsp.JsonRPCMessage.ID = switch (id_value) {
            .integer => |number| .{ .number = number },
            .string => |string| .{ .string = string },
            else => return false,
        };

        const uri = partRequestUri(root.get("params")) orelse {
            try self.child.writeErrorResponse(
                io,
                allocator,
                id,
                .{ .code = .invalid_params, .message = "invalid pngine part URI" },
                .{ .emit_null_optional_fields = false },
            );
            return true;
        };

        const result = self.server.pnginePart(allocator, .{ .uri = uri }) catch |err| {
            try self.child.writeErrorResponse(
                io,
                allocator,
                id,
                .{ .code = partErrorCode(err), .message = partErrorMessage(err) },
                .{ .emit_null_optional_fields = false },
            );
            return true;
        };
        defer allocator.free(result.text);
        try self.child.writeResponse(
            io,
            allocator,
            id,
            NativeServer.PnginePartResult,
            result,
            .{ .emit_null_optional_fields = false },
        );
        return true;
    }

    fn partRequestUri(params: ?std.json.Value) ?[]const u8 {
        const value = params orelse return null;
        const object = switch (value) {
            .object => |object| object,
            else => return null,
        };
        const uri = object.get("uri") orelse return null;
        return switch (uri) {
            .string => |string| string,
            else => null,
        };
    }

    fn partErrorCode(err: anyerror) lsp.JsonRPCMessage.Response.Error.Code {
        return switch (err) {
            error.MissingPart => @enumFromInt(-32010),
            error.StalePart => @enumFromInt(-32011),
            error.InvalidPartUri, error.NotInlinePart => .invalid_params,
            else => .internal_error,
        };
    }

    fn partErrorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.InvalidPartUri => "invalid pngine part URI",
            error.MissingPart => "missing part",
            error.StalePart => "stale part",
            error.NotInlinePart => "not an inline part",
            error.PngineStoreUnbound => "pngine project store unavailable",
            error.PngineUnsupported => "pngine project support unavailable",
            else => "pngine part unavailable",
        };
    }
};
