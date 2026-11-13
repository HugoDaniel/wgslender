//! Canonical path and URI identity for pngine shader projects.
//!
//! This module is deliberately pure `std` + a single `:?[]u8` stat call:
//!
//!   * `fileUriToPathFor` / `pathToFileUriFor` own URI *spelling*. They
//!     decode and encode, but never normalize the filesystem identity.
//!   * `normalizeLexicalFor` collapses `.`, `..`, repeated separators, and
//!     Windows drive/UNC roots without touching the filesystem.
//!   * `canonicalExisting` is the only operation that may stat; it
//!     canonicalizes an existing target (resolving symlinks) or returns
//!     `null` for a missing one. It never opens or reads file text — every
//!     project text read belongs to `SourceProvider.readText`.
//!
//! URI spelling for responses and canonical filesystem identity are two
//! different values on purpose: two URIs can name one file (a symlink alias
//! or a different percent spelling), and a response must keep the caller's
//! spelling while lookups use the canonical identity.
//!
//! Windows rules are selected through `Flavor`, not guessed from the host.
//! The POSIX test host therefore pins `file:///C:/…`, UNC, separator, and
//! case-insensitive lookup rules without changing native POSIX behaviour.
//! `nativeFlavor()` is what production entry points use.
//!
//! ## Complexity and memory
//!
//! Decode/encode/normalize are O(n) time and one allocation of about the
//! input length. `canonicalExisting` is one `realpath(3)`-class stat and one
//! allocated copy. None of these functions recurses.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Which platform's path syntax and lookup rules the caller is asking for.
pub const Flavor = enum { posix, windows };

/// The host's native rules. `windows` only when the build target is Windows;
/// every other target keeps POSIX's case-sensitive, `/`-separated identity.
pub fn nativeFlavor() Flavor {
    return if (builtin.os.tag == .windows) .windows else .posix;
}

/// Convert a `file://` URI to a filesystem path, percent-decoded.
///
/// POSIX: the triple-slash form `file:///…` is required and the authority
/// form `file://host/…` is rejected. Windows: `file:///C:/…` becomes
/// `C:/…`, `file://server/share/…` becomes the UNC path
/// `//server/share/…`, and `localhost` is dropped. Returns `null` for a
/// non-`file:` URI or a URI with no path component.
pub fn fileUriToPathFor(allocator: Allocator, uri: []const u8, flavor: Flavor) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    if (rest.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (flavor) {
        .posix => {
            // POSIX file URIs require `file:///`; the authority form is a
            // Windows UNC spelling and must not silently decode to `/host/…`.
            if (rest[0] != '/') return null;
            try appendPercentDecoded(allocator, &out, rest);
        },
        .windows => {
            if (rest[0] == '/') {
                // `file:///C:/…` → `C:/…`; a POSIX-shaped
                // `file:///tmp/…` keeps its leading slash.
                var local = rest;
                if (rest.len >= 3 and isAsciiLetter(rest[1]) and rest[2] == ':') {
                    local = rest[1..];
                }
                try appendPercentDecoded(allocator, &out, local);
            } else {
                const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
                const authority = rest[0..slash];
                if (authority.len == 0) return null;
                const path = rest[slash..];
                if (std.ascii.eqlIgnoreCase(authority, "localhost")) {
                    if (path.len >= 4 and path[0] == '/' and isAsciiLetter(path[1]) and path[2] == ':') {
                        try appendPercentDecoded(allocator, &out, path[1..]);
                    } else {
                        try appendPercentDecoded(allocator, &out, path);
                    }
                } else {
                    try out.appendSlice(allocator, "//");
                    try appendPercentDecoded(allocator, &out, authority);
                    try appendPercentDecoded(allocator, &out, path);
                }
            }
        },
    }

    return try out.toOwnedSlice(allocator);
}

/// Native-flavour wrapper for `fileUriToPathFor`.
pub fn fileUriToPath(allocator: Allocator, uri: []const u8) !?[]u8 {
    return fileUriToPathFor(allocator, uri, nativeFlavor());
}

/// Encode an absolute filesystem path as a `file://` URI.
///
/// POSIX: the path must start with `/`; `%20`, `#`, and non-ASCII bytes are
/// percent-encoded while `/` stays a separator. Windows: a drive path
/// becomes `file:///C:/…` and a UNC path becomes `file://server/share/…`.
/// Relative paths are refused with `error.NotAbsolute`; inventing a base
/// directory here would create a URI that names the wrong file.
///
/// This preserves the caller's path spelling as the URI spelling (after the
/// Windows separator normalization needed to classify it). Compare
/// `canonicalExisting` for identity.
pub fn pathToFileUriFor(allocator: Allocator, path: []const u8, flavor: Flavor) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (flavor) {
        .posix => {
            if (!std.mem.startsWith(u8, path, "/")) return error.NotAbsolute;
            try out.appendSlice(allocator, "file://");
            try appendEncoded(allocator, &out, path);
        },
        .windows => {
            const normalized = try normalizeLexicalFor(allocator, path, .windows);
            defer allocator.free(normalized);
            if (normalized.len >= 2 and isAsciiLetter(normalized[0]) and normalized[1] == ':') {
                try out.appendSlice(allocator, "file:///");
                try appendEncoded(allocator, &out, normalized);
            } else if (std.mem.startsWith(u8, normalized, "//")) {
                // `//server/share/…` — `file:` plus the two slashes is the
                // authority separator, not an empty path segment.
                try out.appendSlice(allocator, "file:");
                try appendEncoded(allocator, &out, normalized);
            } else {
                return error.NotAbsolute;
            }
        },
    }

    return try out.toOwnedSlice(allocator);
}

/// Native-flavour wrapper for `pathToFileUriFor`.
pub fn pathToFileUri(allocator: Allocator, path: []const u8) ![]u8 {
    return pathToFileUriFor(allocator, path, nativeFlavor());
}

/// Collapse `.`, `..`, repeated separators, and Windows drive/UNC roots in
/// `path`, without touching the filesystem.
///
/// The result keeps the caller's case (identity folding is separate), drops
/// a trailing separator, and cannot climb above an absolute root, a drive
/// root, or a UNC share. A relative path that resolves to the current
/// directory becomes `"."`; an empty input stays empty.
pub fn normalizeLexicalFor(allocator: Allocator, path: []const u8, flavor: Flavor) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, "");

    var work = try allocator.dupe(u8, path);
    defer allocator.free(work);
    if (flavor == .windows) {
        for (work) |*c| {
            if (c.* == '\\') c.* = '/';
        }
    }

    var absolute = false;
    var drive: ?u8 = null;
    var unc_server: ?[]const u8 = null;
    var unc_share: ?[]const u8 = null;
    var start: usize = 0;

    if (flavor == .windows) {
        if (work.len >= 2 and isAsciiLetter(work[0]) and work[1] == ':') {
            absolute = true;
            drive = work[0];
            start = 2;
        } else if (work.len >= 2 and work[0] == '/' and work[1] == '/') {
            absolute = true;
            var i: usize = 2;
            const server_start = i;
            while (i < work.len and work[i] != '/') i += 1;
            if (i == server_start) return allocator.dupe(u8, "");
            unc_server = work[server_start..i];
            if (i < work.len) i += 1;
            const share_start = i;
            while (i < work.len and work[i] != '/') i += 1;
            if (i > share_start) unc_share = work[share_start..i];
            start = i;
        } else if (work[0] == '/') {
            absolute = true;
            start = 1;
        }
    } else if (work[0] == '/') {
        absolute = true;
        start = 1;
    }

    // Collapse the separators that follow an absolute root, then split the
    // remaining components. Components are slices into `work`, so no second
    // pass over the output is needed.
    if (absolute) {
        while (start < work.len and work[start] == '/') start += 1;
    }

    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);

    var i = start;
    while (i < work.len) {
        while (i < work.len and work[i] == '/') i += 1;
        if (i >= work.len) break;
        const component_start = i;
        while (i < work.len and work[i] != '/') i += 1;
        const component = work[component_start..i];

        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0 and
                !std.mem.eql(u8, components.items[components.items.len - 1], ".."))
            {
                _ = components.pop();
            } else if (!absolute) {
                try components.append(allocator, component);
            }
            continue;
        }
        try components.append(allocator, component);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (drive) |letter| {
        try out.append(allocator, letter);
        try out.appendSlice(allocator, ":/");
        try appendJoined(allocator, &out, components.items);
    } else if (unc_server) |server| {
        try out.appendSlice(allocator, "//");
        try out.appendSlice(allocator, server);
        if (unc_share) |share| {
            try out.append(allocator, '/');
            try out.appendSlice(allocator, share);
        }
        if (components.items.len > 0) {
            try out.append(allocator, '/');
            try appendJoined(allocator, &out, components.items);
        }
    } else if (absolute) {
        try out.append(allocator, '/');
        try appendJoined(allocator, &out, components.items);
    } else if (components.items.len == 0) {
        try out.append(allocator, '.');
    } else {
        try appendJoined(allocator, &out, components.items);
    }

    return try out.toOwnedSlice(allocator);
}

/// Native-flavour wrapper for `normalizeLexicalFor`.
pub fn normalizeLexical(allocator: Allocator, path: []const u8) ![]u8 {
    return normalizeLexicalFor(allocator, path, nativeFlavor());
}

/// Return the canonical path of an existing target, or `null` if the target
/// does not exist. Symlink aliases resolve to the same string. An absolute
/// input yields an absolute canonical path; a relative input is resolved
/// against the current directory handle and yields a relative path. Project
/// callers join a document's relative `:file` against its canonical absolute
/// document directory first, so project identity is absolute.
///
/// This is the only function in the module that touches the filesystem, and
/// it only canonicalizes — it never opens the path for reading. Missing
/// intermediate directories, missing files, and dangling links are `null`;
/// permission and path-shape failures are returned as errors rather than
/// being mistaken for absence.
pub fn canonicalExisting(allocator: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    // `std.Io.Dir.realPathFile` is not implemented by the Threaded backend
    // on OpenBSD (it returns `error.OperationUnsupported`), the gate host.
    // On Windows it is the native implementation; elsewhere resolve the
    // components here with `statFile(follow_symlinks = false)` + `readLink`.
    if (builtin.os.tag == .windows) {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        return try allocator.dupe(u8, buffer[0..length]);
    }
    return canonicalPosix(allocator, io, path);
}

/// Resolve a path component by component, following symlinks and applying
/// `.`/`..` after a link is followed (the reason a lexical pre-pass is not
/// enough). Returns `null` when any component is missing. An absolute input
/// yields an absolute canonical path; a relative input is resolved against
/// the current directory handle and yields a relative path (project callers
/// pass absolute paths). Bounded by a symlink-hop limit; the resolved
/// components live in a temporary arena released before returning.
fn canonicalPosix(allocator: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    var absolute = std.mem.startsWith(u8, path, "/");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var queue: std.ArrayList([]const u8) = .empty;
    try appendPathComponents(arena, &queue, path);

    var resolved: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    var hops: usize = 0;

    while (index < queue.items.len) {
        const component = queue.items[index];
        index += 1;

        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (resolved.items.len > 0 and
                !std.mem.eql(u8, resolved.items[resolved.items.len - 1], ".."))
            {
                _ = resolved.pop();
            } else if (!absolute) {
                try resolved.append(arena, component);
            }
            continue;
        }

        const current = try joinComponents(arena, resolved.items, component, absolute);
        const stat = std.Io.Dir.cwd().statFile(io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };

        if (stat.kind == .sym_link) {
            hops += 1;
            if (hops > 40) return error.SymLinkLoop;

            const target_buffer = try arena.alloc(u8, std.Io.Dir.max_path_bytes);
            const target_result = if (absolute)
                std.Io.Dir.readLinkAbsolute(io, current, target_buffer)
            else
                std.Io.Dir.cwd().readLink(io, current, target_buffer);
            const target_length = target_result catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                else => return err,
            };
            const target = target_buffer[0..target_length];

            var next: std.ArrayList([]const u8) = .empty;
            if (std.mem.startsWith(u8, target, "/")) {
                resolved.clearRetainingCapacity();
                absolute = true;
            }
            try appendPathComponents(arena, &next, target);
            try next.appendSlice(arena, queue.items[index..]);
            queue = next;
            index = 0;
            continue;
        }

        try resolved.append(arena, try arena.dupe(u8, component));
    }

    if (resolved.items.len == 0) {
        return try allocator.dupe(u8, if (absolute) "/" else ".");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (absolute) try out.append(allocator, '/');
    try appendJoined(allocator, &out, resolved.items);
    return try out.toOwnedSlice(allocator);
}

/// Canonical identity for a path: `canonicalExisting` when the target
/// exists, otherwise `normalizeLexical` so a missing file still has a stable
/// lexical identity. Callers resolve relative references against their
/// document directory before calling this, so the fallback is absolute too.
pub fn canonicalPath(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (try canonicalExisting(allocator, io, path)) |existing| return existing;
    return normalizeLexical(allocator, path);
}

/// Lookup key for a normalized path. Windows identity folds ASCII case;
/// POSIX identity keeps it. The result is owned by the caller.
pub fn identityKeyFor(allocator: Allocator, path: []const u8, flavor: Flavor) ![]u8 {
    const key = try normalizeLexicalFor(allocator, path, flavor);
    if (flavor == .windows) {
        for (key) |*c| c.* = std.ascii.toLower(c.*);
    }
    return key;
}

/// Native-flavour wrapper for `identityKeyFor`.
pub fn identityKey(allocator: Allocator, path: []const u8) ![]u8 {
    return identityKeyFor(allocator, path, nativeFlavor());
}

fn isAsciiLetter(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Split a `/`-separated path into components (empty and root markers
/// dropped). Slices point into `path`, whose lifetime must cover the list.
fn appendPathComponents(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    path: []const u8,
) Allocator.Error!void {
    var i: usize = 0;
    if (path.len > 0 and path[0] == '/') i = 1;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        try list.append(allocator, path[start..i]);
    }
}

/// Build the path to the next component: `/`-rooted when absolute, the
/// joined resolved components otherwise.
fn joinComponents(
    allocator: Allocator,
    components: []const []const u8,
    last: []const u8,
    absolute: bool,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (absolute) try out.append(allocator, '/');
    try appendJoined(allocator, &out, components);
    if (components.len > 0) try out.append(allocator, '/');
    try out.appendSlice(allocator, last);
    return try out.toOwnedSlice(allocator);
}

fn appendJoined(allocator: Allocator, out: *std.ArrayList(u8), components: []const []const u8) !void {
    for (components, 0..) |component, index| {
        if (index > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, component);
    }
}

fn appendPercentDecoded(allocator: Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
}

fn appendEncoded(allocator: Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (isUriPathByte(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexUpper(c >> 4));
            try out.append(allocator, hexUpper(c));
        }
    }
}

/// RFC 3986 unreserved, plus the path/authority bytes this encoder must keep
/// literal: `/` separators and the `:` of a Windows drive. Everything else,
/// including space and `#`, is percent-encoded.
fn isUriPathByte(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => true,
        else => false,
    };
}

fn hexUpper(n: u8) u8 {
    const digits = "0123456789ABCDEF";
    return digits[n & 0x0f];
}
