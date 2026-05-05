//! Native `workspace/executeCommand` adapter. Routes by command name to
//! the matching `Handler.run*` entry point. Returns a result `std.json.Value`
//! for data-producing commands or `null` for the void-mode commands —
//! the NativeServer wrapper republishes on `null` to reflect mode changes.

const std = @import("std");
const lsp = @import("lsp");
const wgslender = @import("wgslender");
const Handler = @import("Handler");
const lspkit = @import("lspkit");
const ws_codec = lspkit.workspace_commands;

pub fn handle(
    h: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.workspace.execute_command.Params,
) !?std.json.Value {
    if (std.mem.eql(u8, params.command, "wgslender.showMinifiedOutput")) {
        return try runShowMinifiedOutput(h, arena, params.arguments);
    }
    if (std.mem.eql(u8, params.command, "wgslender.reflect")) {
        return try runReflect(h, arena, params.arguments);
    }
    h.executeCommand(params.command, params.arguments) catch |err| switch (err) {
        error.UnknownCommand => return error.MethodNotFound,
        error.InvalidParams => return error.InvalidParams,
        error.DocumentNotFound => return error.InvalidParams,
        error.MinifyFailed, error.ReflectFailed => return error.InternalError,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return null;
}

fn runShowMinifiedOutput(
    h: *Handler,
    arena: std.mem.Allocator,
    arguments: ?[]const std.json.Value,
) !std.json.Value {
    const items = arguments orelse return error.InvalidParams;
    if (items.len < 1) return error.InvalidParams;
    const uri = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    const result = h.runShowMinifiedOutput(arena, uri) catch |err| switch (err) {
        error.UnknownCommand => return error.MethodNotFound,
        error.InvalidParams => return error.InvalidParams,
        error.DocumentNotFound => return error.InvalidParams,
        error.MinifyFailed, error.ReflectFailed => return error.InternalError,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return try ws_codec.toLspKitShowMinifiedOutput(arena, result);
}

fn runReflect(
    h: *Handler,
    arena: std.mem.Allocator,
    arguments: ?[]const std.json.Value,
) !std.json.Value {
    const items = arguments orelse return error.InvalidParams;
    if (items.len < 1) return error.InvalidParams;
    const uri = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    var version: wgslender.Reflect.JsonVersion = .v2;
    if (items.len >= 2) {
        const fmt_str = switch (items[1]) {
            .string => |s| s,
            .null => "v2",
            else => return error.InvalidParams,
        };
        if (std.mem.eql(u8, fmt_str, "v1")) {
            version = .v1;
        } else if (std.mem.eql(u8, fmt_str, "v2")) {
            version = .v2;
        } else return error.InvalidParams;
    }
    var pretty = false;
    if (items.len >= 3) switch (items[2]) {
        .bool => |b| pretty = b,
        .null => {},
        else => return error.InvalidParams,
    };
    const result = h.runReflect(arena, uri, version, pretty) catch |err| switch (err) {
        error.UnknownCommand => return error.MethodNotFound,
        error.InvalidParams => return error.InvalidParams,
        error.DocumentNotFound => return error.InvalidParams,
        error.MinifyFailed, error.ReflectFailed => return error.InternalError,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return try ws_codec.toLspKitReflectResult(arena, result);
}
