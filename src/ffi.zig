//! Shared FFI helpers for WASM entry points (`src/wasm.zig` and
//! `lsp/wasm.zig`). Both surfaces transfer bytes to/from JS through
//! `std.heap.wasm_allocator`-owned buffers and use the same length-prefixed
//! envelope shape (`[u32 len][u8... bytes]`).
//!
//! All helpers reference `std.heap.wasm_allocator` from inside function
//! bodies (never at module top level), so importing this module from a
//! non-wasm target is safe as long as no helper is called from native
//! code. Native builds get the declarations elided by Zig's lazy
//! analysis.

const std = @import("std");

/// Allocate a buffer JS can write into. Returns null on OOM.
/// The caller owns the buffer until the matching `freeBuf` call.
pub fn allocBuf(len: u32) ?[*]u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a buffer previously returned by `allocBuf` or by `packLenPrefixed`.
pub fn freeBuf(ptr: [*]u8, len: u32) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

/// Pack `bytes` as `[u32 len][u8... bytes]` into a freshly-allocated
/// `wasm_allocator` buffer. Returns null on OOM. Caller transfers
/// ownership to JS, which frees via `freeBuf(ptr, 4 + bytes.len)`.
pub fn packLenPrefixed(bytes: []const u8) ?[*]u8 {
    const len = std.math.cast(u32, bytes.len) orelse return null;
    const total = std.math.add(u32, 4, len) catch return null;
    const buf = std.heap.wasm_allocator.alloc(u8, total) catch return null;
    std.mem.writeInt(u32, buf[0..4], len, .little);
    @memcpy(buf[4..][0..bytes.len], bytes);
    return buf.ptr;
}
