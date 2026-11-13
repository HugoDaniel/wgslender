//! pngine project path identity (pngine-shaders phase 01, Task 2).
//!
//! The suite pins the four operations the project store is allowed to use
//! before it opens any project text:
//!
//!   * `fileUriToPath` / `pathToFileUri` — URI spelling, kept separate
//!     from filesystem identity;
//!   * `normalizeLexical` — pure `:`/`.`/`..` normalization, no stat;
//!   * `canonicalExisting` — the only operation allowed to touch the
//!     filesystem, and only to stat/canonicalize (never to read text).
//!
//! Windows forms are exercised through the explicit `Flavor` parameter so
//! the POSIX test host can pin the drive/UNC/case rules without changing
//! platform-native behaviour.

const std = @import("std");
const path = @import("pngine_path");

const testing = std.testing;

fn expectDecoded(uri: []const u8, flavor: path.Flavor, expected: []const u8) !void {
    const got = (try path.fileUriToPathFor(testing.allocator, uri, flavor)) orelse
        return error.TestExpectedPath;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectNotDecoded(uri: []const u8, flavor: path.Flavor) !void {
    if (try path.fileUriToPathFor(testing.allocator, uri, flavor)) |got| {
        testing.allocator.free(got);
        return error.TestUnexpectedPath;
    }
}

fn expectNormalized(input: []const u8, flavor: path.Flavor, expected: []const u8) !void {
    const got = try path.normalizeLexicalFor(testing.allocator, input, flavor);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectUri(flavor: path.Flavor, input: []const u8, expected: []const u8) !void {
    const got = try path.pathToFileUriFor(testing.allocator, input, flavor);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "fileUriToPath: POSIX forms, percent escapes, and non-file URIs" {
    try expectDecoded("file:///tmp/a.wgsl", .posix, "/tmp/a.wgsl");
    try expectDecoded("file:///tmp/My%20Shader.wgsl", .posix, "/tmp/My Shader.wgsl");
    try expectDecoded("file:///tmp/a%23b.wgsl", .posix, "/tmp/a#b.wgsl");
    try expectDecoded("file:///tmp/%E2%9C%93.wgsl", .posix, "/tmp/\xe2\x9c\x93.wgsl");
    try expectDecoded("file:///", .posix, "/");
    // Invalid escapes pass through as literal bytes, as the existing LSP
    // helper does: a bare `%` is a legal file-name byte.
    try expectDecoded("file:///a%XY/b", .posix, "/a%XY/b");
    try expectDecoded("file:///a%2", .posix, "/a%2");
    try expectDecoded("file:///a%", .posix, "/a%");

    try expectNotDecoded("https://example.com/a.wgsl", .posix);
    try expectNotDecoded("untitled:Untitled-1", .posix);
    try expectNotDecoded("file://", .posix);
    // POSIX keeps rejecting `file://host/path`; the authority form is a
    // Windows UNC spelling, selected by flavour rather than guessed.
    try expectNotDecoded("file://host/share/a.wgsl", .posix);
}

test "fileUriToPath: Windows drive and UNC forms" {
    try expectDecoded("file:///C:/Users/Hugo/My%20Project", .windows, "C:/Users/Hugo/My Project");
    try expectDecoded("file:///c:/tmp/a.wgsl", .windows, "c:/tmp/a.wgsl");
    try expectDecoded("file://server/share/My%20File.wgsl", .windows, "//server/share/My File.wgsl");
    try expectDecoded("file://server/share", .windows, "//server/share");
    try expectDecoded("file:///C:/", .windows, "C:/");
    // The same bytes under the POSIX rule are a native POSIX path; the
    // flavour decides, not the text.
    try expectDecoded("file:///C:/Users/Hugo", .posix, "/C:/Users/Hugo");
}

test "pathToFileUri: POSIX spelling and round-trip" {
    try expectUri(.posix, "/tmp/a.wgsl", "file:///tmp/a.wgsl");
    try expectUri(.posix, "/", "file:///");
    try expectUri(.posix, "/tmp/My Project/a#b.wgsl", "file:///tmp/My%20Project/a%23b.wgsl");

    const uri = try path.pathToFileUriFor(testing.allocator, "/tmp/My Project/a#b.wgsl", .posix);
    defer testing.allocator.free(uri);
    const back = (try path.fileUriToPathFor(testing.allocator, uri, .posix)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("/tmp/My Project/a#b.wgsl", back);
}

test "pathToFileUri: Windows drive and UNC spelling and round-trip" {
    try expectUri(.windows, "C:\\Users\\Hugo\\My Project", "file:///C:/Users/Hugo/My%20Project");
    try expectUri(.windows, "c:/tmp/a.wgsl", "file:///c:/tmp/a.wgsl");
    try expectUri(.windows, "\\\\server\\share\\My File.wgsl", "file://server/share/My%20File.wgsl");

    const uri = try path.pathToFileUriFor(testing.allocator, "\\\\server\\share\\My File.wgsl", .windows);
    defer testing.allocator.free(uri);
    const back = (try path.fileUriToPathFor(testing.allocator, uri, .windows)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("//server/share/My File.wgsl", back);
}

test "pathToFileUri: relative paths are refused, never guessed" {
    try testing.expectError(error.NotAbsolute, path.pathToFileUriFor(testing.allocator, "kernels/a.wgsl", .posix));
    try testing.expectError(error.NotAbsolute, path.pathToFileUriFor(testing.allocator, "kernels\\a.wgsl", .windows));
}

test "normalizeLexical: POSIX . and .. collapse without stat" {
    try expectNormalized("/a/./b/../c//", .posix, "/a/c");
    try expectNormalized("a/./b/../c", .posix, "a/c");
    try expectNormalized("a/../../b", .posix, "../b");
    try expectNormalized("/../../x", .posix, "/x");
    try expectNormalized("//a///b", .posix, "/a/b");
    try expectNormalized(".", .posix, ".");
    try expectNormalized("a/..", .posix, ".");
    try expectNormalized("", .posix, "");
}

test "normalizeLexical: Windows separators, drive, and UNC roots" {
    try expectNormalized("C:\\Users\\Hugo\\..\\Hugo\\x", .windows, "C:/Users/Hugo/x");
    try expectNormalized("C:\\..\\x", .windows, "C:/x");
    try expectNormalized("C:/Users/../", .windows, "C:/");
    try expectNormalized("\\\\Server\\Share\\a\\..\\b", .windows, "//Server/Share/b");
    try expectNormalized("\\\\Server\\Share\\..\\..\\b", .windows, "//Server/Share/b");
    try expectNormalized("..\\x", .windows, "../x");
}

test "identityKey: POSIX is case-sensitive, Windows is case-folded" {
    const alloc = testing.allocator;

    const posix_a = try path.identityKeyFor(alloc, "/Users/Foo.WGSL", .posix);
    defer alloc.free(posix_a);
    const posix_b = try path.identityKeyFor(alloc, "/Users/foo.wgsl", .posix);
    defer alloc.free(posix_b);
    try testing.expect(!std.mem.eql(u8, posix_a, posix_b));

    const win_a = try path.identityKeyFor(alloc, "C:/Users/Foo.WGSL", .windows);
    defer alloc.free(win_a);
    const win_b = try path.identityKeyFor(alloc, "c:\\users\\foo.wgsl", .windows);
    defer alloc.free(win_b);
    try testing.expectEqualStrings(win_a, win_b);
}

test "canonicalExisting: a missing target is null; lexical identity survives" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The test runner's cwd is the worktree; canonicalExisting accepts a
    // relative path as well as an absolute one, and returns the same form.
    const missing = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/missing.wgsl", .{&tmp.sub_path});
    defer alloc.free(missing);

    try testing.expect((try path.canonicalExisting(alloc, io, missing)) == null);

    const lexical = try path.canonicalPath(alloc, io, missing);
    defer alloc.free(lexical);
    try testing.expectEqualStrings(missing, lexical);
}

test "canonicalExisting: a symlink and its target share one identity" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.wgsl", .data = "fn f() {}" });
    try tmp.dir.symLink(io, "real.wgsl", "alias.wgsl", .{});

    const real_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/real.wgsl", .{&tmp.sub_path});
    defer alloc.free(real_path);
    const alias_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/alias.wgsl", .{&tmp.sub_path});
    defer alloc.free(alias_path);

    const real_canon = (try path.canonicalExisting(alloc, io, real_path)).?;
    defer alloc.free(real_canon);
    const alias_canon = (try path.canonicalExisting(alloc, io, alias_path)).?;
    defer alloc.free(alias_canon);
    try testing.expectEqualStrings(real_canon, alias_canon);
    // The alias really was the path that was resolved, not a lexical copy.
    try testing.expect(std.mem.indexOf(u8, alias_canon, "real.wgsl") != null);
}

test "URI spelling stays separate from canonical identity" {
    const alloc = testing.allocator;

    const spelled = try path.pathToFileUri(alloc, "/tmp/x/../a.wgsl");
    defer alloc.free(spelled);
    const direct = try path.pathToFileUri(alloc, "/tmp/a.wgsl");
    defer alloc.free(direct);
    try testing.expect(!std.mem.eql(u8, spelled, direct));

    const spelled_key = try path.identityKeyFor(alloc, "/tmp/x/../a.wgsl", .posix);
    defer alloc.free(spelled_key);
    const direct_key = try path.identityKeyFor(alloc, "/tmp/a.wgsl", .posix);
    defer alloc.free(direct_key);
    try testing.expectEqualStrings(spelled_key, direct_key);
}
