//! Provider-only pngine project discovery (pngine-shaders phase 01, Task 4).
//!
//! A discovery pass enumerates candidate `.sjon` documents and ancestors
//! exclusively through `Types.SourceProvider`; nothing here can open a path.
//! The scanner is iterative (a queue, not recursion) and bounded by
//! `Types.DiscoveryLimits`. Hitting a limit, failing to list a directory,
//! failing to read a candidate, or finding a malformed `sjon-lsp.sjon` never
//! turns into an empty "no project" answer: the scan reports an incomplete
//! reason instead.
//!
//! Marker files contribute candidate patterns only. Membership is never
//! inferred from a marker.

const std = @import("std");
const sjon = @import("sjon");
const types = @import("Types.zig");

const Allocator = std.mem.Allocator;

/// The marker file read next to project documents.
pub const marker_name = "sjon-lsp.sjon";

/// One candidate document and the exact bytes read for it.
pub const Document = struct {
    path: []const u8,
    text: []const u8,
};

/// One completed discovery pass. Everything in it is arena-owned; call
/// `deinit` exactly once.
pub const Scan = struct {
    arena: std.heap.ArenaAllocator,
    documents: []const Document = &.{},
    /// Every directory the pass actually enumerated (for ancestor-cache
    /// seeding).
    dirs: []const []const u8 = &.{},
    /// Non-null when the pass was partial. The string names the first cause.
    incomplete_reason: ?[]const u8 = null,

    pub fn deinit(self: *Scan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Scan every workspace root recursively. All roots are searched; overlapping
/// roots and repeated candidates dedupe by canonical document path.
pub fn scanWorkspace(
    gpa: Allocator,
    provider: types.SourceProvider,
    roots: []const []const u8,
    limits: types.DiscoveryLimits,
) !Scan {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var scanner = Scanner{
        .arena = arena.allocator(),
        .provider = provider,
        .limits = limits,
    };

    var queue: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        const normalized = try normalize(scanner.arena, root);
        try queue.append(scanner.arena, normalized);
    }

    var index: usize = 0;
    while (index < queue.items.len and !scanner.stop) : (index += 1) {
        try scanner.scanDirectory(queue.items[index], &queue);
    }

    return scanner.finish(&arena);
}

/// Walk the ancestors of `wgsl_path`, inspecting each directory's immediate
/// `.sjon` files and marker bundle. Directories already present in
/// `skip_dirs` are passed over but the walk continues above them (so a file
/// inside a scanned workspace can still find a project in a parent). Stops
/// at the filesystem root.
pub fn scanAncestors(
    gpa: Allocator,
    provider: types.SourceProvider,
    wgsl_path: []const u8,
    limits: types.DiscoveryLimits,
    skip_dirs: *const std.StringHashMapUnmanaged(void),
) !Scan {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var scanner = Scanner{
        .arena = arena.allocator(),
        .provider = provider,
        .limits = limits,
    };

    const normalized = try normalize(scanner.arena, wgsl_path);
    var current: ?[]const u8 = std.fs.path.dirname(normalized);
    var steps: usize = 0;
    var empty_queue: std.ArrayList([]const u8) = .empty;

    while (current) |dir| {
        if (scanner.stop) break;
        if (steps >= limits.max_directories) {
            try scanner.note("ancestor discovery exceeded the {d}-directory limit at '{s}'", .{ limits.max_directories, dir });
            break;
        }
        steps += 1;

        if (!skip_dirs.contains(dir)) {
            try scanner.scanDirectory(dir, &empty_queue);
        }

        const parent = std.fs.path.dirname(dir);
        if (parent) |value| {
            if (std.mem.eql(u8, value, dir)) break;
            current = value;
        } else {
            current = null;
        }
    }

    return scanner.finish(&arena);
}

const MarkerPattern = struct {
    dir: []const u8,
    pattern: []const u8,
};

const Scanner = struct {
    arena: Allocator,
    provider: types.SourceProvider,
    limits: types.DiscoveryLimits,

    documents: std.StringHashMapUnmanaged([]const u8) = .{},
    visited: std.StringHashMapUnmanaged(void) = .{},
    dirs: std.ArrayList([]const u8) = .empty,
    patterns: std.ArrayList(MarkerPattern) = .empty,
    reason: ?[]const u8 = null,
    stop: bool = false,
    input_bytes: usize = 0,

    fn note(self: *Scanner, comptime format: []const u8, args: anytype) !void {
        if (self.reason != null) return;
        self.reason = try std.fmt.allocPrint(self.arena, format, args);
    }

    /// Enumerate one directory, queue child directories, and load immediate
    /// `.sjon` candidates. Never recurses.
    fn scanDirectory(self: *Scanner, dir: []const u8, queue: *std.ArrayList([]const u8)) !void {
        if (self.stop or self.visited.contains(dir)) return;
        if (self.dirs.items.len >= self.limits.max_directories) {
            self.stop = true;
            try self.note(
                "discovery exceeded the {d}-directory limit while scanning '{s}'",
                .{ self.limits.max_directories, dir },
            );
            return;
        }

        const owned_dir = try self.arena.dupe(u8, dir);
        try self.visited.put(self.arena, owned_dir, {});
        try self.dirs.append(self.arena, owned_dir);

        const entries = self.provider.candidates(self.arena, owned_dir) catch |err| {
            try self.note("cannot enumerate '{s}': {s}", .{ owned_dir, @errorName(err) });
            return;
        };
        std.mem.sort(types.Candidate, entries, {}, struct {
            fn lessThan(_: void, a: types.Candidate, b: types.Candidate) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);

        // Marker first: it contributes patterns for this directory even if a
        // direct candidate later proves unreadable.
        for (entries) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.basename(entry.path), marker_name)) continue;
            try self.loadMarker(owned_dir, entry.path);
        }

        for (entries) |entry| {
            if (self.stop) return;
            switch (entry.kind) {
                .directory => try queue.append(self.arena, entry.path),
                .file => {
                    if (!std.mem.endsWith(u8, entry.path, ".sjon")) continue;
                    if (std.mem.eql(u8, std.fs.path.basename(entry.path), marker_name)) continue;
                    try self.loadDocument(entry.path);
                },
            }
        }
    }

    fn loadDocument(self: *Scanner, path: []const u8) !void {
        if (self.documents.contains(path)) return;
        if (self.documents.count() >= self.limits.max_candidates) {
            self.stop = true;
            try self.note(
                "discovery exceeded the {d}-candidate limit at '{s}'",
                .{ self.limits.max_candidates, path },
            );
            return;
        }

        const text = self.provider.readText(self.arena, path) catch |err| {
            try self.note("cannot read candidate '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        try self.countInput(path, text);
        if (self.stop) return;
        try self.documents.put(self.arena, try self.arena.dupe(u8, path), text);
    }

    fn loadMarker(self: *Scanner, dir: []const u8, path: []const u8) !void {
        const text = self.provider.readText(self.arena, path) catch |err| {
            try self.note("cannot read marker '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        try self.countInput(path, text);
        if (self.stop) return;

        var patterns = collectMarkerPatterns(self.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.MalformedMarker => {
                try self.note("malformed marker '{s}' contributes no patterns", .{path});
                return;
            },
        };
        defer patterns.deinit(self.arena);

        for (patterns.patterns.items) |pattern| {
            try self.patterns.append(self.arena, .{
                .dir = try self.arena.dupe(u8, dir),
                .pattern = try self.arena.dupe(u8, pattern),
            });
        }
    }

    fn countInput(self: *Scanner, path: []const u8, text: []const u8) !void {
        if (self.input_bytes + text.len > self.limits.max_input_bytes) {
            self.stop = true;
            try self.note(
                "discovery exceeded the {d}-byte input limit at '{s}'",
                .{ self.limits.max_input_bytes, path },
            );
            return;
        }
        self.input_bytes += text.len;
    }

    /// Resolve marker patterns after the walk. Globs match documents already
    /// found (deduping is by path); a glob-free pattern that names no found
    /// document is read explicitly so a missing marker-referenced document is
    /// named in the incomplete reason (D26).
    fn expandMarkers(self: *Scanner) !void {
        for (self.patterns.items) |entry| {
            if (hasGlob(entry.pattern)) continue;
            const resolved = try resolveAgainst(self.arena, entry.dir, entry.pattern);
            if (self.documents.contains(resolved)) continue;
            if (self.documents.count() >= self.limits.max_candidates) {
                self.stop = true;
                try self.note(
                    "discovery exceeded the {d}-candidate limit at '{s}'",
                    .{ self.limits.max_candidates, resolved },
                );
                continue;
            }
            const text = self.provider.readText(self.arena, resolved) catch |err| {
                try self.note(
                    "missing project document '{s}' referenced by {s}: {s}",
                    .{ resolved, marker_name, @errorName(err) },
                );
                continue;
            };
            try self.countInput(resolved, text);
            if (self.stop) continue;
            try self.documents.put(self.arena, resolved, text);
        }
    }

    fn finish(self: *Scanner, arena: *std.heap.ArenaAllocator) !Scan {
        try self.expandMarkers();

        const documents = try self.arena.alloc(Document, self.documents.count());
        var index: usize = 0;
        var it = self.documents.iterator();
        while (it.next()) |entry| : (index += 1) {
            documents[index] = .{ .path = entry.key_ptr.*, .text = entry.value_ptr.* };
        }
        std.mem.sort(Document, documents, {}, struct {
            fn lessThan(_: void, a: Document, b: Document) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);

        return .{
            .arena = arena.*,
            .documents = documents,
            .dirs = try self.dirs.toOwnedSlice(self.arena),
            .incomplete_reason = self.reason,
        };
    }
};

const MarkerPatterns = struct {
    patterns: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *MarkerPatterns, gpa: Allocator) void {
        for (self.patterns.items) |pattern| gpa.free(pattern);
        self.patterns.deinit(gpa);
        self.* = undefined;
    }
};

/// Read the `:files` patterns of every `(bundle …)` inside a
/// `(sjon-lsp :version 1 :bundles [ … ])` marker. Returns owned copies.
fn collectMarkerPatterns(gpa: Allocator, source: []const u8) !MarkerPatterns {
    const terminated = try gpa.dupeZ(u8, source);
    defer gpa.free(terminated);

    var tree = try sjon.parse(gpa, terminated);
    defer tree.deinit();
    if (tree.hasErrors()) return error.MalformedMarker;

    var result = MarkerPatterns{};
    errdefer result.deinit(gpa);

    var saw_marker = false;
    for (tree.root) |node| {
        if (tree.tagOf(node) != .form) continue;
        const header = tree.formHeader(node);
        if (std.mem.eql(u8, header.head, "sjon-lsp")) {
            saw_marker = true;
            const bundles = findValue(&tree, node, "bundles") orelse continue;
            if (tree.tagOf(bundles) != .vector) return error.MalformedMarker;
            for (tree.vectorElements(bundles)) |element| {
                if (tree.tagOf(element) != .form) return error.MalformedMarker;
                try appendBundlePatterns(gpa, &tree, element, &result);
            }
        } else if (std.mem.eql(u8, header.head, "bundle")) {
            try appendBundlePatterns(gpa, &tree, node, &result);
        }
    }
    if (!saw_marker and result.patterns.items.len == 0) return error.MalformedMarker;

    return result;
}

fn appendBundlePatterns(
    gpa: Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
    result: *MarkerPatterns,
) !void {
    const header = tree.formHeader(node);
    if (!std.mem.eql(u8, header.head, "bundle")) return error.MalformedMarker;
    const files = findValue(tree, node, "files") orelse return;
    if (tree.tagOf(files) != .vector) return error.MalformedMarker;
    for (tree.vectorElements(files)) |element| {
        if (tree.tagOf(element) != .string) return error.MalformedMarker;
        try result.patterns.append(gpa, try gpa.dupe(u8, tree.stringText(element)));
    }
}

fn findValue(
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
    key: []const u8,
) ?sjon.Ast.NodeIndex {
    for (tree.formHeader(node).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const pair = tree.kvpairHeader(child);
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return null;
}

fn hasGlob(pattern: []const u8) bool {
    for (pattern) |c| {
        if (c == '*' or c == '?' or c == '{') return true;
    }
    return false;
}

fn normalize(allocator: Allocator, path: []const u8) ![]const u8 {
    const path_mod = @import("pngine_path");
    return path_mod.normalizeLexical(allocator, path);
}

fn resolveAgainst(allocator: Allocator, dir: []const u8, pattern: []const u8) ![]const u8 {
    const joined = if (std.fs.path.isAbsolute(pattern))
        try allocator.dupe(u8, pattern)
    else
        try std.fs.path.join(allocator, &.{ dir, pattern });
    return normalize(allocator, joined);
}
