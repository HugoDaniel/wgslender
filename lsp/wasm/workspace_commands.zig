//! WASM workspace command adapters: workspace/executeCommand,
//! wgslender/recomputeMinifyInsights, wgslender/reflect.
//!
//! After void-mode `executeCommand` calls, `republishAllDocuments` is
//! invoked so a minify-mode toggle takes effect immediately.

const std = @import("std");
const Handler = @import("Handler");
const wgslender = @import("wgslender");
const wire = @import("wire");
const json = wire.primitives;
const wire_workspace = wire.workspace_commands;
const wasm_diagnostics = @import("diagnostics.zig");
const wasm_lifecycle = @import("lifecycle.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    handler: *Handler,
    outbox: *std.ArrayList([]u8),
    sendResult: *const fn (id: ?std.json.Value, result_json: []const u8) void,
    sendErrorCode: *const fn (id: ?std.json.Value, code: i32, message: []const u8) void,
    /// Forwarded to wasm_lifecycle.republishAllDocuments after a void-mode
    /// `executeCommand` so settings changes propagate immediately.
    lifecycleCtx: wasm_lifecycle.Ctx,

    fn diagCtx(self: Ctx) wasm_diagnostics.Ctx {
        return .{ .gpa = self.gpa, .handler = self.handler, .outbox = self.outbox };
    }
};

pub fn handleRecomputeMinifyInsights(ctx: Ctx, root: std.json.ObjectMap) void {
    const uri = json.extractUri(root) orelse return;
    ctx.handler.refreshMinifyInsights(uri);
    wasm_diagnostics.emitDiagnostics(ctx.diagCtx(), uri);
}

pub fn handleReflect(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    if (id == null) return;
    const params = root.getPtr("params") orelse return ctx.sendErrorCode(id, -32602, "missing params");
    const td = json.objGet(params, "textDocument") orelse return ctx.sendErrorCode(id, -32602, "missing textDocument.uri");
    const uri = json.strVal(json.objGet(td, "uri")) orelse return ctx.sendErrorCode(id, -32602, "missing textDocument.uri");

    var version: wgslender.Reflect.JsonVersion = .v2;
    if (json.objGet(params, "format")) |fmt_val| switch (fmt_val.*) {
        .string => |s| {
            if (std.mem.eql(u8, s, "v1")) {
                version = .v1;
            } else if (std.mem.eql(u8, s, "v2")) {
                version = .v2;
            } else return ctx.sendErrorCode(id, -32602, "format must be 'v1' or 'v2'");
        },
        else => return ctx.sendErrorCode(id, -32602, "format must be a string"),
    };

    var pretty = false;
    if (json.objGet(params, "pretty")) |p| switch (p.*) {
        .bool => |b| pretty = b,
        else => {},
    };

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const result = ctx.handler.runReflect(arena.allocator(), uri, version, pretty) catch |err| {
        switch (err) {
            error.UnknownCommand => ctx.sendErrorCode(id, -32601, "unknown command"),
            error.InvalidParams => ctx.sendErrorCode(id, -32602, "invalid params"),
            error.DocumentNotFound => ctx.sendErrorCode(id, -32602, "document not found"),
            error.MinifyFailed => ctx.sendErrorCode(id, -32603, "reflect failed"),
            error.ReflectFailed => ctx.sendErrorCode(id, -32603, "reflect failed"),
            error.OutOfMemory => ctx.sendErrorCode(id, -32603, "out of memory"),
        }
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    wire_workspace.appendReflectResult(&buf, ctx.gpa, result);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleConstInventory(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    if (id == null) return;
    const params = root.getPtr("params") orelse return ctx.sendErrorCode(id, -32602, "missing params");
    const td = json.objGet(params, "textDocument") orelse return ctx.sendErrorCode(id, -32602, "missing textDocument.uri");
    const uri = json.strVal(json.objGet(td, "uri")) orelse return ctx.sendErrorCode(id, -32602, "missing textDocument.uri");

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const result = ctx.handler.runConstInventory(arena.allocator(), uri) catch |err| {
        switch (err) {
            error.UnknownCommand => ctx.sendErrorCode(id, -32601, "unknown command"),
            error.InvalidParams => ctx.sendErrorCode(id, -32602, "invalid params"),
            error.DocumentNotFound => ctx.sendErrorCode(id, -32602, "document not found"),
            error.MinifyFailed => ctx.sendErrorCode(id, -32603, "const inventory failed"),
            error.ReflectFailed => ctx.sendErrorCode(id, -32603, "const inventory failed"),
            error.OutOfMemory => ctx.sendErrorCode(id, -32603, "out of memory"),
        }
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    wire_workspace.appendConstInventoryResult(&buf, ctx.gpa, result);
    ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
}

pub fn handleExecuteCommand(ctx: Ctx, root: std.json.ObjectMap, id: ?std.json.Value) void {
    const params = root.getPtr("params") orelse {
        if (id != null) ctx.sendErrorCode(id, -32602, "missing params");
        return;
    };
    const command = json.strVal(json.objGet(params, "command")) orelse {
        if (id != null) ctx.sendErrorCode(id, -32602, "missing command");
        return;
    };
    var args_slice: ?[]const std.json.Value = null;
    if (json.objGet(params, "arguments")) |a| switch (a.*) {
        .array => |arr| args_slice = arr.items,
        .null => {},
        else => {
            if (id != null) ctx.sendErrorCode(id, -32602, "arguments must be an array");
            return;
        },
    };
    if (std.mem.eql(u8, command, Handler.command_ids.id.show_minified_output)) {
        if (id == null) return;
        const items = args_slice orelse return ctx.sendErrorCode(id, -32602, "missing uri");
        if (items.len < 1) return ctx.sendErrorCode(id, -32602, "missing uri");
        const uri = switch (items[0]) {
            .string => |s| s,
            else => return ctx.sendErrorCode(id, -32602, "uri must be a string"),
        };
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();
        const result = ctx.handler.runShowMinifiedOutput(arena.allocator(), uri) catch |err| {
            switch (err) {
                error.UnknownCommand => ctx.sendErrorCode(id, -32601, "unknown command"),
                error.InvalidParams => ctx.sendErrorCode(id, -32602, "invalid command arguments"),
                error.DocumentNotFound => ctx.sendErrorCode(id, -32602, "document not found"),
                error.MinifyFailed => ctx.sendErrorCode(id, -32603, "minify failed"),
                error.ReflectFailed => ctx.sendErrorCode(id, -32603, "reflect failed"),
                error.OutOfMemory => ctx.sendErrorCode(id, -32603, "out of memory"),
            }
            return;
        };
        var buf: std.ArrayList(u8) = .empty;
        wire_workspace.appendShowMinifiedOutput(&buf, ctx.gpa, result);
        ctx.sendResult(id, buf.toOwnedSlice(ctx.gpa) catch return);
        return;
    }
    ctx.handler.executeCommand(command, args_slice) catch |err| {
        if (id == null) return;
        switch (err) {
            error.UnknownCommand => ctx.sendErrorCode(id, -32601, "unknown command"),
            error.InvalidParams => ctx.sendErrorCode(id, -32602, "invalid command arguments"),
            error.DocumentNotFound => ctx.sendErrorCode(id, -32602, "document not found"),
            error.MinifyFailed => ctx.sendErrorCode(id, -32603, "minify failed"),
            error.ReflectFailed => ctx.sendErrorCode(id, -32603, "reflect failed"),
            error.OutOfMemory => ctx.sendErrorCode(id, -32603, "out of memory"),
        }
        return;
    };
    // Re-publish diagnostics so any minify-mode change takes effect
    // immediately across all open documents.
    wasm_lifecycle.republishAllDocuments(ctx.lifecycleCtx);
    if (id != null) ctx.sendResult(id, "null");
}
