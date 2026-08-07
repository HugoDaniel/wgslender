//! Native ↔ WASM capability-advertisement parity.
//!
//! The native server advertises `lsp/native/lifecycle.zig`'s
//! `server_capabilities` (an lsp-kit struct); the WASM transport
//! advertises `Handler.capabilities_json` (a hand-written blob). They
//! describe the same Handler, so they must offer the same feature set —
//! this harness is what keeps a capability from landing on one
//! transport and silently missing from the other (editors never call a
//! method that isn't advertised, so the drift is invisible at runtime).
//!
//! The one sanctioned divergence is `executeCommandProvider`: the
//! command *lists* differ by design (`command_ids.native` vs
//! `command_ids.shared`), so that key is compared for presence only.

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const native_lifecycle = @import("native_lifecycle");
const helpers = @import("lsp_parity_helpers.zig");

fn parseNative(arena: std.mem.Allocator) !std.json.ObjectMap {
    const value = try helpers.writeAndParseResult(
        arena,
        lsp.types.ServerCapabilities,
        native_lifecycle.server_capabilities,
    );
    return value.object;
}

fn parseWasm(arena: std.mem.Allocator) !std.json.ObjectMap {
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        Handler.capabilities_json,
        .{},
    );
    return value.object;
}

fn expectSameKeySet(want: std.json.ObjectMap, got: std.json.ObjectMap, direction: []const u8) !void {
    var ok = true;
    var it = want.iterator();
    while (it.next()) |entry| {
        if (got.get(entry.key_ptr.*) == null) {
            std.debug.print("capability {s} advertised by {s} only\n", .{ entry.key_ptr.*, direction });
            ok = false;
        }
    }
    if (!ok) return error.CapabilityKeySetMismatch;
}

test "parity: native and wasm advertise the same capability keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const native = try parseNative(arena);
    const wasm = try parseWasm(arena);

    try expectSameKeySet(wasm, native, "wasm");
    try expectSameKeySet(native, wasm, "native");
}

test "parity: capability values are identical except executeCommandProvider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const native = try parseNative(arena);
    const wasm = try parseWasm(arena);

    var ok = true;
    var it = wasm.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "executeCommandProvider")) continue;
        const native_value = native.get(key) orelse continue; // key-set test reports absence
        if (!helpers.jsonEql(entry.value_ptr.*, native_value)) {
            std.debug.print("capability {s} differs between transports\n", .{key});
            ok = false;
        }
    }
    try std.testing.expect(ok);
}

test "both transports advertise the full go-to navigation family" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const native = try parseNative(arena);
    const wasm = try parseWasm(arena);

    const family = [_][]const u8{
        "declarationProvider",
        "definitionProvider",
        "typeDefinitionProvider",
        "referencesProvider",
        "documentHighlightProvider",
        "documentSymbolProvider",
        "renameProvider",
        "callHierarchyProvider",
        "hoverProvider",
    };
    var ok = true;
    for (family) |key| {
        if (native.get(key) == null) {
            std.debug.print("native does not advertise {s}\n", .{key});
            ok = false;
        }
        if (wasm.get(key) == null) {
            std.debug.print("wasm does not advertise {s}\n", .{key});
            ok = false;
        }
    }
    try std.testing.expect(ok);
}
