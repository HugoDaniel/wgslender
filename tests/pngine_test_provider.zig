//! In-memory `SourceProvider` for the pngine discovery/store suites.
//!
//! The project code is only allowed to reach project text and candidate
//! documents through `Types.SourceProvider`; these tests bind this fake and
//! never let the store touch the host filesystem. Corpus-shaped fixture
//! files under `tests/testdata/pngine/` are compiled in with `@embedFile`,
//! so even the fixture contents are compile-time inputs.

const std = @import("std");
const wgslender = @import("wgslender");

const Types = wgslender.Pngine.Types;

const corpus = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "/ws/clock/program.sjon", .text = @embedFile("testdata/pngine/clock/program.sjon") },
    .{ .path = "/ws/clock/kernels/scene_lib.wgsl", .text = @embedFile("testdata/pngine/clock/kernels/scene_lib.wgsl") },
    .{ .path = "/ws/clock/kernels/clock_scene.wgsl", .text = @embedFile("testdata/pngine/clock/kernels/clock_scene.wgsl") },
    .{ .path = "/ws/clock/kernels/clock_vec.wgsl", .text = @embedFile("testdata/pngine/clock/kernels/clock_vec.wgsl") },
    .{ .path = "/ws/clock/kernels/clock_frag.wgsl", .text = @embedFile("testdata/pngine/clock/kernels/clock_frag.wgsl") },
    .{ .path = "/ws/clock/kernels/clock_post.wgsl", .text = @embedFile("testdata/pngine/clock/kernels/clock_post.wgsl") },
    .{ .path = "/ws/clock/shaders/scene.wgsl", .text = @embedFile("testdata/pngine/clock/shaders/scene.wgsl") },
    .{ .path = "/ws/demo/program.sjon", .text = @embedFile("testdata/pngine/demo/program.sjon") },
    .{ .path = "/ws/demo/palette.wgsl", .text = @embedFile("testdata/pngine/demo/palette.wgsl") },
    .{ .path = "/ws/demo/bg.wgsl", .text = @embedFile("testdata/pngine/demo/bg.wgsl") },
    .{ .path = "/ws/demo/squares.wgsl", .text = @embedFile("testdata/pngine/demo/squares.wgsl") },
    .{ .path = "/ws/demo/post.wgsl", .text = @embedFile("testdata/pngine/demo/post.wgsl") },
    .{ .path = "/ws/demo/composite.wgsl", .text = @embedFile("testdata/pngine/demo/composite.wgsl") },
    .{ .path = "/ws/bounce/program.sjon", .text = @embedFile("testdata/pngine/bounce/program.sjon") },
    .{ .path = "/ws/bounce/bouncing-sq.wgsl", .text = @embedFile("testdata/pngine/bounce/bouncing-sq.wgsl") },
    .{ .path = "/ws/veclock/program.sjon", .text = @embedFile("testdata/pngine/veclock/program.sjon") },
    .{ .path = "/ws/veclock/clock_vec.wgsl", .text = @embedFile("testdata/pngine/veclock/clock_vec.wgsl") },
    .{ .path = "/ws/veclock/kernels/circle.wgsl", .text = @embedFile("testdata/pngine/veclock/kernels/circle.wgsl") },
};

/// A provider over an in-memory tree. Directories are inferred from file
/// paths, so a tree is exactly the set of files the test registered.
pub const FakeProvider = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]u8) = .{},
    fail_reads: std.StringHashMapUnmanaged(void) = .{},
    read_calls: usize = 0,
    /// Reads whose path names a `.sjon` document. A warm WGSL keystroke must
    /// not re-parse a project graph, and this is the observable the perf
    /// gate asserts against.
    sjon_read_calls: usize = 0,
    /// Reads whose path does not name a `.sjon` document (WGSL sources).
    wgsl_read_calls: usize = 0,
    candidate_calls: usize = 0,

    pub fn init(gpa: std.mem.Allocator) FakeProvider {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeProvider) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit(self.gpa);
        var fail_it = self.fail_reads.iterator();
        while (fail_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.fail_reads.deinit(self.gpa);
    }

    pub fn addCorpus(self: *FakeProvider) !void {
        for (corpus) |fixture| try self.addFile(fixture.path, fixture.text);
    }

    pub fn addFile(self: *FakeProvider, path: []const u8, text: []const u8) !void {
        if (self.files.getPtr(path)) |value| {
            self.gpa.free(value.*);
            value.* = try self.gpa.dupe(u8, text);
            return;
        }
        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        try self.files.put(self.gpa, owned_path, owned_text);
    }

    pub fn removeFile(self: *FakeProvider, path: []const u8) void {
        if (self.files.fetchRemove(path)) |entry| {
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
        }
    }

    pub fn failReads(self: *FakeProvider, path: []const u8) !void {
        if (self.fail_reads.contains(path)) return;
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.fail_reads.put(self.gpa, owned, {});
    }

    pub fn allowReads(self: *FakeProvider, path: []const u8) void {
        if (self.fail_reads.fetchRemove(path)) |entry| self.gpa.free(entry.key);
    }

    pub fn sourceProvider(self: *FakeProvider) Types.SourceProvider {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = Types.SourceProvider.VTable{
        .read_text = readText,
        .candidates = candidates,
    };

    fn readText(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        if (std.mem.endsWith(u8, path, ".sjon")) {
            self.sjon_read_calls += 1;
        } else {
            self.wgsl_read_calls += 1;
        }
        if (self.fail_reads.contains(path)) return error.FileNotFound;
        const text = self.files.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, text);
    }

    fn candidates(context: *anyopaque, allocator: std.mem.Allocator, dir: []const u8) anyerror![]Types.Candidate {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        self.candidate_calls += 1;

        var list: std.ArrayList(Types.Candidate) = .empty;
        errdefer {
            for (list.items) |candidate| allocator.free(candidate.path);
            list.deinit(allocator);
        }

        var file_it = self.files.iterator();
        while (file_it.next()) |entry| {
            const parent = std.fs.path.dirname(entry.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, parent, dir)) continue;
            try list.append(allocator, .{
                .path = try allocator.dupe(u8, entry.key_ptr.*),
                .kind = .file,
            });
        }

        // Directories are exactly the parent chains of registered files.
        var dirs: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = dirs.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            dirs.deinit(allocator);
        }
        var infer_it = self.files.iterator();
        while (infer_it.next()) |entry| {
            var current = std.fs.path.dirname(entry.key_ptr.*);
            while (current) |value| {
                if (dirs.contains(value)) break;
                const owned = try allocator.dupe(u8, value);
                errdefer allocator.free(owned);
                try dirs.put(allocator, owned, {});
                current = std.fs.path.dirname(value);
            }
        }

        var dir_it = dirs.iterator();
        while (dir_it.next()) |entry| {
            const parent = std.fs.path.dirname(entry.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, parent, dir)) continue;
            try list.append(allocator, .{
                .path = try allocator.dupe(u8, entry.key_ptr.*),
                .kind = .directory,
            });
        }

        std.mem.sort(Types.Candidate, list.items, {}, struct {
            fn lessThan(_: void, a: Types.Candidate, b: Types.Candidate) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return list.toOwnedSlice(allocator);
    }
};
