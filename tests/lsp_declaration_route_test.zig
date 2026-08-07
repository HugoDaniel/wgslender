//! `textDocument/declaration` on the native dispatcher. WGSL has no
//! forward declarations, so a symbol's declaration IS its definition —
//! the route must exist (editors surface "Go to Declaration" as its own
//! action) and must answer exactly what `textDocument/definition`
//! answers. The WASM transport's declaration route is exercised
//! end-to-end by `npm/wgslender-lsp/test.js` and the VS Code suite.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const NativeServer = @import("NativeServer");
const helpers = @import("lsp_parity_helpers.zig");

/// Discards writes so NativeServer methods can run without a stdio pipe.
const NullTransport = struct {
    transport: lsp.Transport = .{
        .vtable = &.{
            .readJsonMessage = readJsonMessage,
            .writeJsonMessage = writeJsonMessage,
        },
    },

    fn readJsonMessage(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(_: *lsp.Transport, _: std.Io, _: []const u8) lsp.Transport.WriteError!void {}
};

fn setupServer() !*NativeServer {
    const ptr = try std.testing.allocator.create(NativeServer);
    const transport_box = try std.testing.allocator.create(NullTransport);
    transport_box.* = .{};
    ptr.* = NativeServer.init(std.testing.allocator, &transport_box.transport, std.testing.io);
    return ptr;
}

fn teardownServer(server: *NativeServer) void {
    const transport_box: *NullTransport = @fieldParentPtr("transport", server.transport);
    server.deinit();
    std.testing.allocator.destroy(transport_box);
    std.testing.allocator.destroy(server);
}

const uri = "test://decl.wgsl";

const source: [:0]const u8 =
    \\struct Particle { pos: vec4f }
    \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
    \\fn integrate(p: Particle) -> Particle { return p; }
    \\@compute @workgroup_size(64) fn main() {
    \\  let p = particles[0];
    \\  particles[0] = integrate(p);
    \\}
;

/// LSP position of `needle`'s first byte match in `source`.
fn positionOf(needle: []const u8) lsp.types.Position {
    const offset = std.mem.indexOf(u8, source, needle).?;
    const pos = Handler.offsetToLspPosition(source, @intCast(offset)).?;
    return .{ .line = pos.line, .character = pos.character };
}

fn expectSameAnswer(server: *NativeServer, position: lsp.types.Position) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const decl = server.@"textDocument/declaration"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = position,
    });
    const def = server.@"textDocument/definition"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = position,
    });

    try std.testing.expect(decl != null);
    try std.testing.expect(def != null);

    const decl_json = try helpers.writeAndParseResult(arena, lsp.types.Definition.Result, decl.?);
    const def_json = try helpers.writeAndParseResult(arena, lsp.types.Definition.Result, def.?);
    try helpers.expectEqualJson(def_json, decl_json);
}

test "declaration answers exactly what definition answers, per symbol kind" {
    const server = try setupServer();
    defer teardownServer(server);
    try server.handler.openDocument(uri, source, 1);

    // struct type ref, module var usage, fn call, local let usage
    try expectSameAnswer(server, positionOf("Particle>"));
    try expectSameAnswer(server, positionOf("particles[0] ="));
    try expectSameAnswer(server, positionOf("integrate(p)"));
    try expectSameAnswer(server, positionOf("p);"));
}

test "declaration on whitespace returns null like definition" {
    const server = try setupServer();
    defer teardownServer(server);
    try server.handler.openDocument(uri, source, 1);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const decl = server.@"textDocument/declaration"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 3, .character = 39 },
    });
    try std.testing.expect(decl == null);
}
