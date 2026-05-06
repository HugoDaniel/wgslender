//! `file://` URI → filesystem path conversion. Used by the native LSP
//! entry to honor `InitializeParams.{workspaceFolders,rootUri}` when
//! picking a `wgslender.json` discovery root.
//!
//! Posix-only today: paths under a `file:///...` triple-slash URI with
//! `%XX` percent-decoding. The Windows `file:///C:/...` form would
//! decode to `/C:/...` and break `Dir.openDir`, so the entry point
//! falls back to cwd in that case (clean follow-up if Windows support
//! lands).

const std = @import("std");

/// Convert `file:///path` to a freshly-allocated filesystem path.
/// Returns `null` for non-`file://` URIs, the `file://host/path` form
/// (no triple slash), or an empty path. The caller owns the returned
/// slice and must free it with `allocator`.
pub fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const after_scheme = uri[prefix.len..];
    // Posix file URIs require `file:///` (three slashes), so the
    // remainder must start with `/`. Reject `file://hostname/path` —
    // we don't speak SMB-style paths.
    if (after_scheme.len == 0 or after_scheme[0] != '/') return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < after_scheme.len) : (i += 1) {
        const c = after_scheme[i];
        if (c == '%' and i + 2 < after_scheme.len) {
            const hi = std.fmt.charToDigit(after_scheme[i + 1], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            const lo = std.fmt.charToDigit(after_scheme[i + 2], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 2;
        } else {
            try out.append(allocator, c);
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "fileUriToPath: simple posix" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///Users/hugo/foo")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/Users/hugo/foo", path);
}

test "fileUriToPath: percent-decoded space" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///Users/hugo/My%20Project")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/Users/hugo/My Project", path);
}

test "fileUriToPath: percent-decoded sequence at end" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///foo/%2E")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/foo/.", path);
}

test "fileUriToPath: invalid percent escape passes through verbatim" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///foo/%XY/bar")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/foo/%XY/bar", path);
}

test "fileUriToPath: percent at end with insufficient hex chars passes through" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///foo/%2")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/foo/%2", path);
}

test "fileUriToPath: rejects non-file scheme" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fileUriToPath(alloc, "https://example.com/foo"));
}

test "fileUriToPath: rejects file://host/path (no triple slash)" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fileUriToPath(alloc, "file://hostname/path"));
}

test "fileUriToPath: rejects file:// with empty path" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fileUriToPath(alloc, "file://"));
}

test "fileUriToPath: root path file:/// returns /" {
    const alloc = std.testing.allocator;
    const path = (try fileUriToPath(alloc, "file:///")).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/", path);
}
