//! Native filesystem binding of `Pngine.Types.SourceProvider`
//! (pngine-shaders phase 01, Task 6).
//!
//! This is the one implementation of the provider that touches the
//! filesystem, and it is imported only by `lsp/NativeServer.zig` — the native
//! LSP graph. `lsp/wasm.zig`, the wasm module graph and the project-free
//! `lib`/`lsp-wasm` graphs never reach this file.
//!
//! Only the two provider operations are exposed: `readText` and `candidates`.
//! No project module above this boundary opens a path itself.

const std = @import("std");
const wgslender = @import("wgslender");

const Types = wgslender.Pngine.Types;

pub const FileProvider = struct {
    io: std.Io = undefined,

    pub fn sourceProvider(self: *FileProvider) Types.SourceProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Types.SourceProvider.VTable{
        .read_text = readText,
        .candidates = candidates,
    };

    fn readText(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited);
    }

    fn candidates(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        dir: []const u8,
    ) anyerror![]Types.Candidate {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        var opened = try std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true });
        defer opened.close(self.io);

        var list: std.ArrayList(Types.Candidate) = .empty;
        errdefer {
            for (list.items) |candidate| allocator.free(candidate.path);
            list.deinit(allocator);
        }

        var it = opened.iterateAssumeFirstIteration();
        while (try it.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const kind: Types.CandidateKind = switch (entry.kind) {
                .directory => .directory,
                else => .file,
            };
            const child = try std.fs.path.join(allocator, &.{ dir, entry.name });
            errdefer allocator.free(child);
            try list.append(allocator, .{ .path = child, .kind = kind });
        }
        return list.toOwnedSlice(allocator);
    }
};
