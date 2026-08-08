//! After a `workspace/configuration` response is applied, the WASM
//! transport must ask the client to re-pull everything whose result
//! depends on settings. Publish-model diagnostics are re-pushed by
//! `republishAllDocuments`, but VS Code consumes the *pull* model
//! (`textDocument/diagnostic`) — without a `workspace/diagnostic/refresh`
//! request the old pull results linger until the next edit, so turning a
//! lint rule off (or diagnostics entirely) appears to do nothing.
//! Same story for inlay hints and code lenses when `lsp.minifyMode`
//! changes: `workspace/inlayHint/refresh` + `workspace/codeLens/refresh`.

const std = @import("std");
const Handler = @import("Handler");
const wasm_lifecycle = @import("wasm_lifecycle");

fn noopSendResult(id: ?std.json.Value, result_json: []const u8) void {
    _ = id;
    _ = result_json;
}

fn outboxContainsMethod(outbox: *const std.ArrayList([]u8), method: []const u8) bool {
    for (outbox.items) |msg| {
        if (std.mem.indexOf(u8, msg, method) != null) return true;
    }
    return false;
}

test "configuration response triggers diagnostic, inlay-hint, and code-lens refresh" {
    const gpa = std.testing.allocator;
    const handler = try gpa.create(Handler);
    handler.* = Handler.init(gpa);
    defer {
        handler.deinit();
        gpa.destroy(handler);
    }
    try handler.openDocument("untitled:a.wgsl", "fn f() {}", 1);

    var outbox: std.ArrayList([]u8) = .empty;
    defer {
        for (outbox.items) |m| gpa.free(m);
        outbox.deinit(gpa);
    }

    var supports = true;
    var next_id: i64 = 7;
    var pending: ?i64 = null;

    const ctx: wasm_lifecycle.Ctx = .{
        .gpa = gpa,
        .handler = handler,
        .outbox = &outbox,
        .client_supports_configuration = &supports,
        .next_request_id = &next_id,
        .pending_config_id = &pending,
        .sendResult = &noopSendResult,
    };

    // The settings-change round trip: server asks for the section…
    wasm_lifecycle.handleDidChangeConfiguration(ctx);
    try std.testing.expect(pending != null);
    const config_id = pending.?;

    // …the client answers with fresh settings.
    const response = try std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"rules\":{{\"no-unused-vars\":\"off\"}}}}]}}",
        .{config_id},
    );
    defer gpa.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, response, .{});
    defer parsed.deinit();
    wasm_lifecycle.handleResponse(ctx, parsed.value.object);

    try std.testing.expect(outboxContainsMethod(&outbox, "\"workspace/diagnostic/refresh\""));
    try std.testing.expect(outboxContainsMethod(&outbox, "\"workspace/inlayHint/refresh\""));
    try std.testing.expect(outboxContainsMethod(&outbox, "\"workspace/codeLens/refresh\""));

    // Each refresh is a request and needs its own id — three sends must
    // have advanced the counter past the configuration request's id.
    try std.testing.expect(next_id >= config_id + 4);
}
