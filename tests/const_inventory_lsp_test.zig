//! Const-inventory over the LSP command path (pacer plans/08 knob-lift,
//! Phase 0 exposure). Drives `Handler.runConstInventory` — the shared
//! handler the WASM `wgslender/constInventory` request delegates to — so
//! the cached-analysis reuse and the `ConstInfo` slice it hands back are
//! exercised the way the studio's Phase-1 client will hit them.

const std = @import("std");
const Handler = @import("Handler");

fn setup(source: [:0]const u8) !*Handler {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    try handler.openDocument("test://k.wgsl", source, 1);
    return handler;
}

fn teardown(handler: *Handler) void {
    handler.deinit();
    std.testing.allocator.destroy(handler);
}

test "runConstInventory: reports consts with liftability through the cached module" {
    const source: [:0]const u8 =
        \\const SPEED: f32 = 0.55;
        \\const N: u32 = 4u;
        \\var<private> cells: array<f32, N>;
        \\@fragment
        \\fn main() -> @location(0) vec4f { return vec4f(SPEED * cells[0]); }
    ;
    const handler = try setup(source);
    defer teardown(handler);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try Handler.runConstInventory(handler, arena.allocator(), "test://k.wgsl");

    try std.testing.expectEqualStrings("test://k.wgsl", result.uri);
    try std.testing.expectEqual(@as(usize, 2), result.consts.len);

    var seen_speed = false;
    var seen_n = false;
    for (result.consts) |c| {
        if (std.mem.eql(u8, c.name, "SPEED")) {
            seen_speed = true;
            try std.testing.expectEqualStrings("f32", c.typ);
            try std.testing.expect(c.liftable);
        } else if (std.mem.eql(u8, c.name, "N")) {
            seen_n = true;
            try std.testing.expect(!c.liftable); // array element count
        }
    }
    try std.testing.expect(seen_speed and seen_n);
}

test "runConstInventory: missing document is DocumentNotFound" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer teardown(handler);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.DocumentNotFound,
        Handler.runConstInventory(handler, arena.allocator(), "test://absent.wgsl"),
    );
}
