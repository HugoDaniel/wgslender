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
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    // Read happens only on the basic_server thread, so `thread_safe_read`
    // can stay off; only writes need serialisation.
    var safe_transport: lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .init(&stdio_transport.transport);
    const transport: *lsp.Transport = &safe_transport.transport;

    var server: NativeServer = .init(init.gpa, transport, init.io);
    defer server.deinit();
    try server.start();

    try lsp.basic_server.run(init.io, init.gpa, transport, &server, std.log.err);
}
