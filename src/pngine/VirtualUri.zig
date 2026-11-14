//! Stable virtual-document URIs for inline pngine parts
//! (pngine-shaders phase 04, Task 6).
//!
//! An inline `:code` part has no file path, but editors still need a
//! document identity that survives reopening and can prove it is serving
//! current text. The URI shape is:
//!
//! ```text
//! wgslender-pngine://part/<percent-encoded-program-path>/<part-index>/<content-hash>
//! ```
//!
//! - the program path is the Store's canonical document path (identity, not
//!   response spelling);
//! - the part index is the source-order occurrence in that program, the same
//!   number `Types.PartId.index` carries;
//! - the content hash is the SHA-256 of the author text the URI was minted
//!   for, lowercase hex. A decoder compares it with `Store.textForPart`
//!   before serving, so changed `:code` is stale rather than silently old.
//!
//! ## Escaping
//!
//! Every byte outside the RFC 3986 unreserved set (`A-Z a-z 0-9 - . _ ~`) is
//! percent-encoded, including `/` and `%`. That makes the encoded path one
//! URI segment, so the three fields are unambiguous. Decoding runs exactly
//! once: a literal `%2F` in a path is encoded as `%252F` and comes back as
//! the three-byte string `%2F`, never as a separator.
//!
//! The module is pure `std`: no Store, no SJON, no LSP. The native server
//! and the desktop extension implement the same codec independently, and
//! the tests pin the byte shape.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const scheme = "wgslender-pngine";
pub const authority = "part";
pub const prefix = scheme ++ "://" ++ authority ++ "/";

const hex_lower = "0123456789abcdef";
const hex_upper = "0123456789ABCDEF";

/// One decoded virtual part identity. `program_path` is owned.
pub const PartUri = struct {
    program_path: []u8,
    part_index: u32,
    content_hash: [32]u8,

    pub fn deinit(self: *PartUri, gpa: Allocator) void {
        gpa.free(self.program_path);
        self.* = undefined;
    }
};

/// Encode `(program_path, part_index, content_hash)` as one virtual URI.
/// The caller owns the returned string.
pub fn encode(
    gpa: Allocator,
    program_path: []const u8,
    part_index: u32,
    content_hash: [32]u8,
) ![]u8 {
    if (program_path.len == 0 or !std.fs.path.isAbsolute(program_path)) {
        return error.InvalidPartUri;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    try appendEscaped(gpa, &out, program_path);
    try out.print(gpa, "/{d}/", .{part_index});
    for (content_hash) |byte| {
        try out.append(gpa, hex_lower[byte >> 4]);
        try out.append(gpa, hex_lower[byte & 0x0f]);
    }
    return out.toOwnedSlice(gpa);
}

/// Decode a virtual part URI. Every malformed shape (wrong scheme, missing
/// field, bad escape, non-decimal index, non-hex hash) returns
/// `error.InvalidPartUri`; no partially decoded identity is returned.
pub fn decode(gpa: Allocator, uri: []const u8) !PartUri {
    if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidPartUri;
    const rest = uri[prefix.len..];

    const first = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidPartUri;
    const encoded_path = rest[0..first];
    if (encoded_path.len == 0) return error.InvalidPartUri;

    const second_rel = std.mem.indexOfScalar(u8, rest[first + 1 ..], '/') orelse
        return error.InvalidPartUri;
    const second = first + 1 + second_rel;
    const index_text = rest[first + 1 .. second];
    const hash_text = rest[second + 1 ..];
    if (index_text.len == 0 or hash_text.len != 64) return error.InvalidPartUri;
    if (std.mem.indexOfScalar(u8, hash_text, '/') != null) return error.InvalidPartUri;

    const part_index = std.fmt.parseInt(u32, index_text, 10) catch
        return error.InvalidPartUri;

    var content_hash: [32]u8 = undefined;
    for (&content_hash, 0..) |*byte, i| {
        const hi = hexValue(hash_text[i * 2]) orelse return error.InvalidPartUri;
        const lo = hexValue(hash_text[i * 2 + 1]) orelse return error.InvalidPartUri;
        byte.* = (hi << 4) | lo;
    }

    const program_path = try decodeEscaped(gpa, encoded_path);
    errdefer gpa.free(program_path);
    if (program_path.len == 0 or !std.fs.path.isAbsolute(program_path)) {
        return error.InvalidPartUri;
    }

    return .{
        .program_path = program_path,
        .part_index = part_index,
        .content_hash = content_hash,
    };
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        if (isUnreserved(byte)) {
            try out.append(gpa, byte);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex_upper[byte >> 4]);
            try out.append(gpa, hex_upper[byte & 0x0f]);
        }
    }
}

fn decodeEscaped(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == '%') {
            if (i + 2 >= text.len) return error.InvalidPartUri;
            const hi = hexValue(text[i + 1]) orelse return error.InvalidPartUri;
            const lo = hexValue(text[i + 2]) orelse return error.InvalidPartUri;
            try out.append(gpa, (hi << 4) | lo);
            i += 3;
        } else if (isUnreserved(byte)) {
            try out.append(gpa, byte);
            i += 1;
        } else {
            // A raw byte that should have been escaped (a separator or a
            // non-ASCII byte) is not a valid spelling.
            return error.InvalidPartUri;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
