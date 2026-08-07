//! Both LSP transports must report the core `wgslender.version` in their
//! `initialize` serverInfo.
//!
//! These were two hand-edited string literals, one per transport, with
//! nothing tying either to `src/root.zig`. Drift there is silent in the
//! worst way: the server keeps working and simply misreports which build
//! it is, so the first symptom is a bug report against a version that was
//! never running. Deriving both from one constant makes the drift
//! unrepresentable; this test is what keeps a future hand-edit from
//! reintroducing it.

const std = @import("std");
const wgslender = @import("wgslender");
const native_lifecycle = @import("native_lifecycle");
const wasm_lifecycle = @import("wasm_lifecycle");

test "native serverInfo reports the core version" {
    try std.testing.expectEqualStrings("wgslender-lsp", native_lifecycle.server_info.name);
    try std.testing.expectEqualStrings(wgslender.version, native_lifecycle.server_info.version.?);
}

test "wasm initialize result reports the core version" {
    // Pins the shape as well as the value: a serverInfo object that stopped
    // carrying a version at all would still satisfy a bare substring search
    // for the version string, which appears nowhere else in the payload only
    // by luck.
    const expected_tail = ",\"serverInfo\":{\"name\":\"wgslender-lsp\",\"version\":\"" ++
        wgslender.version ++ "\"}}";
    try std.testing.expect(std.mem.endsWith(u8, wasm_lifecycle.initialize_result_json, expected_tail));
}
