//! `file://` URI ↔ filesystem path conversion for the native LSP entry.
//! Used to honor `InitializeParams.{workspaceFolders,rootUri}` when picking
//! a `wgslender.json` discovery root, and by the pngine project identity.
//!
//! The conversion itself lives in `src/pngine/Path.zig`, the pure module
//! shared with the project store, so the LSP workspace decode and the
//! project's canonical identity cannot drift into two implementations.
//! POSIX keeps the historical rule: `file:///...` only, percent-decoded,
//! and `file://host/path` rejected. Windows uses the drive/UNC rules in
//! `Path.zig`; `Path.nativeFlavor()` selects between them. `pathToFileUri`
//! is the inverse, kept separate from canonical filesystem identity
//! (`Path.canonicalExisting`) because responses must preserve the caller's
//! URI spelling.

const pngine_path = @import("pngine_path");

pub const fileUriToPath = pngine_path.fileUriToPath;
pub const pathToFileUri = pngine_path.pathToFileUri;

const std = @import("std");

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

test "pathToFileUri: posix root round-trips to file:///" {
    const alloc = std.testing.allocator;
    const uri = try pathToFileUri(alloc, "/");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///", uri);
    const path = (try fileUriToPath(alloc, uri)).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/", path);
}
