//! pngine project store (pngine-shaders phase 01, Tasks 4–5).
//!
//! The store owns the discovered programs, the forward/reverse membership
//! indexes, and the source cache. Every project text read and every candidate
//! enumeration goes through the injected `Types.SourceProvider`; this file
//! never opens a path. Program identity is the canonical document path and a
//! `ProgramId` slot survives a refresh as long as the document does, so root
//! revision keys do not churn when another project changes.

const std = @import("std");
const path_mod = @import("pngine_path");
const types = @import("Types.zig");
const discovery = @import("Discovery.zig");
const extract = @import("Extract.zig");

const Allocator = std.mem.Allocator;

const DocumentStatus = enum { ok, invalid, unsupported };

const ProgramRecord = struct {
    program: ?types.Program = null,
    status: DocumentStatus = .ok,
    /// Discovered by the ancestor fallback rather than a workspace scan.
    external: bool = false,
    /// Full-refresh reaping marker; external programs are never reaped by a
    /// workspace refresh.
    seen: bool = false,
};

const SourceRecord = struct {
    text: []u8,
    hash: [32]u8,
};

const SourceRefresh = struct {
    status: types.SourceStatus,
    /// True when the refreshed bytes differ from a previously cached read,
    /// or an unreadable source became readable/unreadable.
    changed: bool,
};

pub const Store = struct {
    gpa: Allocator,
    provider: types.SourceProvider,
    limits: types.DiscoveryLimits = .{},

    enabled: bool = true,
    roots: std.ArrayList([]u8) = .empty,
    /// `ProgramId` is an index into this list; slots are never reused.
    programs: std.ArrayList(?ProgramRecord) = .empty,
    program_revisions: std.ArrayList(u64) = .empty,
    document_slots: std.StringHashMapUnmanaged(types.ProgramId) = .{},
    ancestor_dirs: std.StringHashMapUnmanaged(void) = .{},

    memberships: []types.Membership = &.{},
    membership_index: std.StringHashMapUnmanaged([]u32) = .{},
    sources: std.StringHashMapUnmanaged(SourceRecord) = .{},
    /// Open buffers, keyed by canonical path. Precedence above injected and
    /// disk text.
    buffers: std.StringHashMapUnmanaged([]u8) = .{},
    /// Provider-injected text (reserved for a future wasm host).
    injected: std.StringHashMapUnmanaged([]u8) = .{},
    /// Per-root revision; bumped only for roots containing an edited part.
    root_revisions: std.AutoHashMapUnmanaged(types.PartId, u64) = .{},

    state: types.DiscoveryState = .none,
    reason: ?[]u8 = null,
    discovery_generation: u64 = 0,
    content_generation: u64 = 0,

    pub fn init(gpa: Allocator, provider: types.SourceProvider) Store {
        return .{ .gpa = gpa, .provider = provider };
    }

    pub fn deinit(self: *Store) void {
        for (self.roots.items) |root| self.gpa.free(root);
        self.roots.deinit(self.gpa);

        for (self.programs.items) |*slot| {
            if (slot.*) |*record| {
                if (record.program) |*value| value.deinit(self.gpa);
                slot.* = null;
            }
        }
        self.programs.deinit(self.gpa);
        self.program_revisions.deinit(self.gpa);

        var slot_it = self.document_slots.iterator();
        while (slot_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.document_slots.deinit(self.gpa);

        var dir_it = self.ancestor_dirs.iterator();
        while (dir_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.ancestor_dirs.deinit(self.gpa);

        self.freeMemberships();
        self.freeMembershipIndex();

        var source_it = self.sources.iterator();
        while (source_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.text);
        }
        self.sources.deinit(self.gpa);

        var buffer_it = self.buffers.iterator();
        while (buffer_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.buffers.deinit(self.gpa);

        var injected_it = self.injected.iterator();
        while (injected_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.injected.deinit(self.gpa);

        self.root_revisions.deinit(self.gpa);

        self.clearReason();
        self.* = undefined;
    }

    pub fn setEnabled(self: *Store, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn isEnabled(self: *const Store) bool {
        return self.enabled;
    }

    pub fn discoveryState(self: *const Store) types.DiscoveryState {
        return self.state;
    }

    pub fn incompleteReason(self: *const Store) ?[]const u8 {
        return self.reason;
    }

    pub fn discoveryGeneration(self: *const Store) u64 {
        return self.discovery_generation;
    }

    pub fn contentGeneration(self: *const Store) u64 {
        return self.content_generation;
    }

    pub fn programRevision(self: *const Store, id: types.ProgramId) u64 {
        if (id >= self.program_revisions.items.len) return 0;
        return self.program_revisions.items[id];
    }

    /// Root cache revision. Starts at 0 and increases only when a root
    /// containing the part sees a content change.
    pub fn rootRevision(self: *const Store, id: types.PartId) u64 {
        return self.root_revisions.get(id) orelse 0;
    }

    /// SHA-256 of the cached provider (disk) text for `source_path`, when it
    /// is currently readable. Overlays are reported by `textForPart`, not
    /// here.
    pub fn sourceHash(self: *Store, source_path: []const u8) ?[32]u8 {
        const normalized = path_mod.normalizeLexical(self.gpa, source_path) catch return null;
        defer self.gpa.free(normalized);
        const record = self.sources.get(normalized) orelse return null;
        return record.hash;
    }

    /// Store or replace an overlay. `origin` selects open-buffer or injected
    /// authority; `disk` is not an overlay and is ignored.
    pub fn upsertBuffer(
        self: *Store,
        uri: []const u8,
        text: []const u8,
        origin: types.SourceOrigin,
    ) !void {
        if (origin == .disk) return;
        const key = try self.pathKey(uri);
        defer self.gpa.free(key);

        const map = switch (origin) {
            .open_buffer => &self.buffers,
            .injected => &self.injected,
            .disk => return,
        };

        if (map.getPtr(key)) |value| {
            if (std.mem.eql(u8, value.*, text)) return;
            self.gpa.free(value.*);
            value.* = try self.gpa.dupe(u8, text);
        } else {
            const owned_key = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned_key);
            const owned_text = try self.gpa.dupe(u8, text);
            errdefer self.gpa.free(owned_text);
            try map.put(self.gpa, owned_key, owned_text);
        }

        self.content_generation += 1;
        try self.bumpRootsForPath(key);
    }

    /// Remove both overlay layers for `uri`. The next source query falls
    /// back to provider text.
    pub fn removeBuffer(self: *Store, uri: []const u8) void {
        const key = self.pathKey(uri) catch return;
        defer self.gpa.free(key);

        var changed = false;
        if (self.buffers.fetchRemove(key)) |entry| {
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
            changed = true;
        }
        if (self.injected.fetchRemove(key)) |entry| {
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
            changed = true;
        }
        if (!changed) return;

        self.content_generation += 1;
        self.bumpRootsForPath(key) catch {};
    }

    /// True when an open-buffer or injected overlay exists for `uri`.
    pub fn hasOverlay(self: *Store, uri: []const u8) bool {
        const key = self.pathKey(uri) catch return false;
        defer self.gpa.free(key);
        return self.buffers.contains(key) or self.injected.contains(key);
    }

    /// Resolve a part's current text under
    /// `open buffer > provider-injected > provider disk`, with the SHA-256 of
    /// exactly the returned bytes. Caller owns the returned text.
    pub fn textForPart(self: *Store, id: types.PartId) !types.SourceText {
        const source_part = self.part(id) orelse return error.UnknownPart;
        switch (source_part.origin) {
            .inline_code => |source| {
                const text = try self.gpa.dupe(u8, source.code);
                return .{
                    .text = text,
                    .origin = .disk,
                    .content_hash = types.contentHash(text),
                };
            },
            .file => |file| {
                const program_value = self.program(id.program) orelse return error.UnknownProgram;
                const source_path = try resolveFile(self.gpa, program_value.document_path, file.path);
                defer self.gpa.free(source_path);
                return self.textForPath(source_path);
            },
        }
    }

    fn textForPath(self: *Store, source_path: []const u8) !types.SourceText {
        if (self.buffers.get(source_path)) |text| {
            const owned = try self.gpa.dupe(u8, text);
            return .{
                .text = owned,
                .origin = .open_buffer,
                .content_hash = types.contentHash(owned),
            };
        }
        if (self.injected.get(source_path)) |text| {
            const owned = try self.gpa.dupe(u8, text);
            return .{
                .text = owned,
                .origin = .injected,
                .content_hash = types.contentHash(owned),
            };
        }
        if (self.sources.get(source_path)) |record| {
            return .{
                .text = try self.gpa.dupe(u8, record.text),
                .origin = .disk,
                .content_hash = record.hash,
            };
        }

        const refresh = self.refreshSource(source_path) catch return error.SourceUnavailable;
        if (refresh.status == .unreadable) return error.SourceUnavailable;
        const record = self.sources.get(source_path) orelse return error.SourceUnavailable;
        return .{
            .text = try self.gpa.dupe(u8, record.text),
            .origin = .disk,
            .content_hash = record.hash,
        };
    }

    /// Re-read one path. A `.sjon` path refreshes only that program (or
    /// removes it on deletion); a marker reruns discovery; any other path is
    /// treated as WGSL source and invalidates only its dependent roots.
    pub fn invalidatePath(self: *Store, path: []const u8) void {
        self.invalidatePathInner(path) catch |err| {
            self.setReason(@errorName(err)) catch {};
        };
    }

    fn invalidatePathInner(self: *Store, path: []const u8) !void {
        const normalized = try path_mod.normalizeLexical(self.gpa, path);
        defer self.gpa.free(normalized);

        if (std.mem.eql(u8, std.fs.path.basename(normalized), discovery.marker_name)) {
            try self.refreshWorkspace();
            return;
        }
        if (std.mem.endsWith(u8, normalized, ".sjon")) {
            if (self.document_slots.contains(normalized)) {
                try self.refreshDocument(normalized);
            } else {
                try self.refreshWorkspace();
            }
            return;
        }

        try self.invalidateSource(normalized);
    }

    /// Replace the workspace roots and refresh discovery over all of them.
    pub fn setWorkspaceRoots(self: *Store, roots: []const []const u8) !void {
        for (self.roots.items) |root| self.gpa.free(root);
        self.roots.clearRetainingCapacity();
        for (roots) |root| {
            const normalized = try path_mod.normalizeLexical(self.gpa, root);
            errdefer self.gpa.free(normalized);
            try self.roots.append(self.gpa, normalized);
        }
        try self.refreshWorkspace();
    }

    /// Content-checked refresh at the LSP boundaries that exist even when
    /// the client never sends `workspace/didChangeWatchedFiles` (D45):
    /// `didOpen`, `didSave`, and explicit project selection. Re-reads every
    /// known project document and every cached source through the provider
    /// and rebuilds the memberships, so a sibling that changed on disk is
    /// picked up at the boundary. Explicit selection itself is
    /// `setWorkspaceRoots`; the first query for an unknown file is the
    /// bounded ancestor walk below.
    pub fn refreshAtBoundary(self: *Store, uri: []const u8) !void {
        if (!self.enabled) return;

        const key = try self.pathKey(uri);
        defer self.gpa.free(key);

        // D35: a non-file URI has no filesystem identity; only an exact
        // overlay/membership match can ever name it, and the boundary
        // refresh must not invent a path to walk.
        if (!std.fs.path.isAbsolute(key)) return;

        if (isDocumentPath(key)) {
            try self.invalidatePathInner(key);
            return;
        }

        if (!self.membership_index.contains(key)) {
            try self.discoverAncestors(key);
        }

        try self.refreshKnownDocuments();
        try self.rebuildIndexes();
        try self.recomputeState();
    }

    /// The reverse index query: every membership whose canonical file is
    /// `wgsl_uri`. The result is sorted by program document path, then part
    /// index. A missing result triggers the bounded ancestor walk.
    pub fn membershipsFor(self: *Store, wgsl_uri: []const u8) !types.MembershipSet {
        if (!self.enabled) return .{};

        const key = try self.pathKey(wgsl_uri);
        defer self.gpa.free(key);

        if (!self.membership_index.contains(key)) {
            try self.discoverAncestors(key);
        }

        const indices = self.membership_index.get(key) orelse return .{};
        var items = try self.gpa.alloc(types.Membership, indices.len);
        errdefer self.gpa.free(items);

        for (indices, 0..) |membership_index, index| {
            const source = self.memberships[membership_index];
            items[index] = .{
                .program = source.program,
                .part = source.part,
                .containing_roots = try self.dupeU32(source.containing_roots),
                .dependants = try self.dupeU32(source.dependants),
                .source_status = source.source_status,
            };
        }
        return .{ .items = items };
    }

    pub fn program(self: *const Store, id: types.ProgramId) ?*const types.Program {
        if (id >= self.programs.items.len) return null;
        if (self.programs.items[id]) |*record| {
            if (record.program) |*value| return value;
        }
        return null;
    }

    pub fn part(self: *const Store, id: types.PartId) ?*const types.Part {
        const program_value = self.program(id.program) orelse return null;
        if (id.index >= program_value.parts.len) return null;
        return &program_value.parts[id.index];
    }

    // ---------------------------------------------------------------------
    // Discovery / refresh
    // ---------------------------------------------------------------------

    fn refreshWorkspace(self: *Store) !void {
        self.discovery_generation += 1;
        self.clearReason();

        for (self.programs.items) |*slot| {
            if (slot.*) |*record| {
                if (!record.external) record.seen = false;
            }
        }

        const roots = try self.gpa.alloc([]const u8, self.roots.items.len);
        defer self.gpa.free(roots);
        for (self.roots.items, 0..) |root, index| roots[index] = root;

        var scan = try discovery.scanWorkspace(self.gpa, self.provider, roots, self.limits);
        defer scan.deinit();

        for (scan.dirs) |dir| try self.recordAncestorDir(dir);
        for (scan.documents) |document| {
            try self.syncDocument(document.path, document.text, false);
        }
        if (scan.incomplete_reason) |reason| try self.setReason(reason);

        try self.reapUnseen();
        try self.rebuildIndexes();
        try self.recomputeState();
    }

    fn discoverAncestors(self: *Store, wgsl_path: []const u8) !void {
        self.discovery_generation += 1;
        var scan = try discovery.scanAncestors(
            self.gpa,
            self.provider,
            wgsl_path,
            self.limits,
            &self.ancestor_dirs,
        );
        defer scan.deinit();

        for (scan.dirs) |dir| try self.recordAncestorDir(dir);
        for (scan.documents) |document| {
            if (self.document_slots.get(document.path)) |id| {
                const record = &self.programs.items[id];
                if (record.*) |*value| {
                    if (value.status == .ok and !(value.program != null and value.program.?.stale)) continue;
                }
            }
            try self.syncDocument(document.path, document.text, true);
        }
        if (scan.incomplete_reason) |reason| try self.setReason(reason);

        try self.rebuildIndexes();
        try self.recomputeState();
    }

    fn refreshDocument(self: *Store, document_path: []const u8) !void {
        self.discovery_generation += 1;
        // A document-level refresh replaces the old reason: the graph now
        // either parses (complete) or contributes its own new reason.
        self.clearReason();
        const external = if (self.document_slots.get(document_path)) |id|
            if (self.programs.items[id]) |record| record.external else false
        else
            false;

        const text = self.provider.readText(self.gpa, document_path) catch {
            try self.removeDocument(document_path);
            try self.rebuildIndexes();
            try self.recomputeState();
            return;
        };
        defer self.gpa.free(text);

        try self.syncDocument(document_path, text, external);
        try self.rebuildIndexes();
        try self.recomputeState();
    }

    /// Re-read every known project document and sync the ones whose content
    /// hash changed. This is the document half of `refreshAtBoundary`; the
    /// source half is `rebuildIndexes`, which refreshes every file-backed
    /// part. Documents that disappeared from the provider are removed, which
    /// drops their memberships (D29).
    fn refreshKnownDocuments(self: *Store) !void {
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |path| self.gpa.free(path);
            paths.deinit(self.gpa);
        }

        var it = self.document_slots.iterator();
        while (it.next()) |entry| {
            try paths.append(self.gpa, try self.gpa.dupe(u8, entry.key_ptr.*));
        }

        for (paths.items) |document_path| {
            const external = if (self.document_slots.get(document_path)) |id|
                if (self.programs.items[id]) |record| record.external else false
            else
                false;

            const text = self.provider.readText(self.gpa, document_path) catch {
                try self.removeDocument(document_path);
                continue;
            };
            defer self.gpa.free(text);

            const hash = types.contentHash(text);
            if (self.document_slots.get(document_path)) |id| {
                if (self.programs.items[id]) |record| {
                    if (record.status == .ok) {
                        if (record.program) |program_value| {
                            if (std.mem.eql(u8, &program_value.document_hash, &hash)) continue;
                        }
                    }
                }
            }
            try self.syncDocument(document_path, text, external);
        }
    }

    fn removeDocument(self: *Store, document_path: []const u8) !void {
        const removed = self.document_slots.fetchRemove(document_path) orelse return;
        const id = removed.value;
        if (id < self.programs.items.len) {
            if (self.programs.items[id]) |*record| {
                if (record.program) |*value| value.deinit(self.gpa);
            }
            self.programs.items[id] = null;
        }
        self.gpa.free(removed.key);
        if (id < self.program_revisions.items.len) self.program_revisions.items[id] += 1;
        self.content_generation += 1;
    }

    fn invalidateSource(self: *Store, source_path: []const u8) !void {
        const refresh = try self.refreshSource(source_path);
        if (self.membership_index.get(source_path)) |indices| {
            for (indices) |index| {
                self.memberships[index].source_status = refresh.status;
            }
        }
        // An open/injected overlay is authoritative; an external disk change
        // must not invalidate roots whose analysis uses the overlay text.
        const has_overlay = self.hasOverlayPath(source_path);
        if (refresh.changed and !has_overlay) {
            self.content_generation += 1;
            try self.bumpRootsForPath(source_path);
        }
    }

    fn bumpRootsForPath(self: *Store, source_path: []const u8) !void {
        const indices = self.membership_index.get(source_path) orelse return;
        for (indices) |index| {
            const membership = self.memberships[index];
            for (membership.containing_roots) |root_index| {
                const key: types.PartId = .{
                    .program = membership.program,
                    .index = root_index,
                };
                const gop = try self.root_revisions.getOrPut(self.gpa, key);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    fn syncDocument(self: *Store, document_path: []const u8, text: []const u8, external: bool) !void {
        const id = try self.slotForDocument(document_path);
        const slot = &self.programs.items[id];
        if (slot.*) |*record| {
            record.seen = true;
            record.external = external;
        } else {
            slot.* = .{ .seen = true, .external = external };
        }

        var result = try extract.extractWithOptions(self.gpa, document_path, text, .{});
        defer result.deinit(self.gpa);

        const record = &slot.*.?;
        switch (result.status) {
            .ok => {
                if (record.program) |*old| old.deinit(self.gpa);
                var program_value = result.program.?;
                result.program = null;
                program_value.stale = false;
                record.program = program_value;
                record.status = .ok;
                if (id < self.program_revisions.items.len) self.program_revisions.items[id] += 1;
                self.content_generation += 1;
            },
            .invalid => {
                record.status = .invalid;
                if (record.program) |*old| old.stale = true;
                try self.noteResultReason(&result);
                self.content_generation += 1;
            },
            .unsupported_document_import => {
                record.status = .unsupported;
                if (record.program) |*old| old.stale = true;
                try self.noteResultReason(&result);
                self.content_generation += 1;
            },
        }
    }

    fn noteResultReason(self: *Store, result: *const types.Result) !void {
        if (self.reason != null) return;
        if (result.diagnostics.len == 0) return;
        self.reason = try self.gpa.dupe(u8, result.diagnostics[0].message);
    }

    fn reapUnseen(self: *Store) !void {
        var remove_paths: std.ArrayList([]const u8) = .empty;
        defer remove_paths.deinit(self.gpa);

        var it = self.document_slots.iterator();
        while (it.next()) |entry| {
            const id = entry.value_ptr.*;
            if (id >= self.programs.items.len) {
                try remove_paths.append(self.gpa, entry.key_ptr.*);
                continue;
            }
            const slot = &self.programs.items[id];
            const unseen = if (slot.*) |record| !record.seen and !record.external else true;
            if (unseen) try remove_paths.append(self.gpa, entry.key_ptr.*);
        }

        for (remove_paths.items) |document_path| {
            const removed = self.document_slots.fetchRemove(document_path) orelse continue;
            const id = removed.value;
            if (id < self.programs.items.len) {
                if (self.programs.items[id]) |*record| {
                    if (record.program) |*value| value.deinit(self.gpa);
                }
                self.programs.items[id] = null;
            }
            self.gpa.free(removed.key);
            if (id < self.program_revisions.items.len) self.program_revisions.items[id] += 1;
            self.content_generation += 1;
        }
    }

    fn slotForDocument(self: *Store, document_path: []const u8) !types.ProgramId {
        if (self.document_slots.get(document_path)) |id| return id;
        const id: types.ProgramId = @intCast(self.programs.items.len);
        try self.programs.append(self.gpa, null);
        errdefer _ = self.programs.pop();
        try self.program_revisions.append(self.gpa, 0);
        errdefer _ = self.program_revisions.pop();

        const owned_path = try self.gpa.dupe(u8, document_path);
        errdefer self.gpa.free(owned_path);
        try self.document_slots.put(self.gpa, owned_path, id);
        return id;
    }

    fn recordAncestorDir(self: *Store, dir: []const u8) !void {
        if (self.ancestor_dirs.contains(dir)) return;
        const owned = try self.gpa.dupe(u8, dir);
        errdefer self.gpa.free(owned);
        try self.ancestor_dirs.put(self.gpa, owned, {});
    }

    fn setReason(self: *Store, message: []const u8) !void {
        if (self.reason != null) return;
        self.reason = try self.gpa.dupe(u8, message);
    }

    fn clearReason(self: *Store) void {
        if (self.reason) |reason| self.gpa.free(reason);
        self.reason = null;
    }

    fn recomputeState(self: *Store) !void {
        var any_unsupported = false;
        var any_invalid = false;
        var any_program = false;
        for (self.programs.items) |slot| {
            const record = slot orelse continue;
            any_program = true;
            switch (record.status) {
                .unsupported => any_unsupported = true,
                .invalid => any_invalid = true,
                .ok => {},
            }
        }

        self.state = if (any_unsupported)
            .unsupported
        else if (self.reason != null or any_invalid)
            .incomplete
        else if (!any_program)
            .none
        else
            .complete;
    }

    // ---------------------------------------------------------------------
    // Membership / reverse index
    // ---------------------------------------------------------------------

    fn rebuildIndexes(self: *Store) !void {
        self.freeMemberships();
        self.freeMembershipIndex();

        const Entry = struct {
            membership: types.Membership,
            path: []u8,
        };

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                if (entry.membership.containing_roots.len > 0) self.gpa.free(entry.membership.containing_roots);
                if (entry.membership.dependants.len > 0) self.gpa.free(entry.membership.dependants);
                self.gpa.free(entry.path);
            }
            entries.deinit(self.gpa);
        }

        var refreshed: std.StringHashMapUnmanaged(SourceRefresh) = .{};
        defer {
            var it = refreshed.iterator();
            while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            refreshed.deinit(self.gpa);
        }

        for (self.programs.items, 0..) |_, slot_index| {
            const record = if (self.programs.items[slot_index]) |*value| value else continue;
            const program_value = if (record.program) |*value| value else continue;
            const program_id: types.ProgramId = @intCast(slot_index);

            const root_count = program_value.roots.len;
            var reachable: []bool = &.{};
            defer if (reachable.len > 0) self.gpa.free(reachable);
            if (root_count > 0 and program_value.parts.len > 0) {
                reachable = try self.gpa.alloc(bool, program_value.parts.len * root_count);
                @memset(reachable, false);
                const visited = try self.gpa.alloc(bool, program_value.parts.len);
                defer self.gpa.free(visited);
                for (program_value.roots, 0..) |root_index, root_offset| {
                    @memset(visited, false);
                    try markClosure(self.gpa, program_value, root_index, visited);
                    for (visited, 0..) |is_reachable, part_index| {
                        if (is_reachable) reachable[part_index * root_count + root_offset] = true;
                    }
                }
            }

            for (program_value.parts, 0..) |source_part, part_index| {
                const file = switch (source_part.origin) {
                    .inline_code => continue,
                    .file => |value| value,
                };
                const resolved = try resolveFile(self.gpa, program_value.document_path, file.path);
                errdefer self.gpa.free(resolved);

                const status = if (refreshed.get(resolved)) |cached|
                    cached.status
                else blk: {
                    const refresh = try self.refreshSource(resolved);
                    const owned = try self.gpa.dupe(u8, resolved);
                    errdefer self.gpa.free(owned);
                    try refreshed.put(self.gpa, owned, refresh);
                    break :blk refresh.status;
                };

                var roots: std.ArrayList(u32) = .empty;
                errdefer roots.deinit(self.gpa);
                if (root_count > 0) {
                    for (program_value.roots, 0..) |root_index, root_offset| {
                        if (reachable[part_index * root_count + root_offset]) {
                            try roots.append(self.gpa, root_index);
                        }
                    }
                }

                var dependants: std.ArrayList(u32) = .empty;
                errdefer dependants.deinit(self.gpa);
                for (program_value.parts, 0..) |candidate, candidate_index| {
                    if (candidate_index == part_index) continue;
                    for (candidate.imports) |import_ref| {
                        if (!std.mem.eql(u8, import_ref.name, source_part.name)) continue;
                        try dependants.append(self.gpa, @intCast(candidate_index));
                        break;
                    }
                }

                const owned_roots = try roots.toOwnedSlice(self.gpa);
                errdefer if (owned_roots.len > 0) self.gpa.free(owned_roots);
                const owned_dependants = try dependants.toOwnedSlice(self.gpa);
                errdefer if (owned_dependants.len > 0) self.gpa.free(owned_dependants);

                try entries.append(self.gpa, .{
                    .membership = .{
                        .program = program_id,
                        .part = .{ .program = program_id, .index = @intCast(part_index) },
                        .containing_roots = owned_roots,
                        .dependants = owned_dependants,
                        .source_status = status,
                    },
                    .path = resolved,
                });
            }
        }

        std.mem.sort(Entry, entries.items, self, struct {
            fn lessThan(store: *const Store, a: Entry, b: Entry) bool {
                const a_program = store.program(a.membership.program) orelse return false;
                const b_program = store.program(b.membership.program) orelse return true;
                const by_path = std.mem.order(u8, a_program.document_path, b_program.document_path);
                if (by_path != .eq) return by_path == .lt;
                return a.membership.part.index < b.membership.part.index;
            }
        }.lessThan);

        const owned_memberships = try self.gpa.alloc(types.Membership, entries.items.len);
        errdefer self.gpa.free(owned_memberships);
        for (entries.items, 0..) |entry, index| owned_memberships[index] = entry.membership;

        // Build path → indices after sorting so the index order matches the
        // public membership order.
        for (entries.items, 0..) |entry, index| {
            const gop = try self.membership_index.getOrPut(self.gpa, entry.path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.gpa.dupe(u8, entry.path);
                gop.value_ptr.* = &.{};
            }
            const old = gop.value_ptr.*;
            const grown = try self.gpa.alloc(u32, old.len + 1);
            @memcpy(grown[0..old.len], old);
            grown[old.len] = @intCast(index);
            if (old.len > 0) self.gpa.free(old);
            gop.value_ptr.* = grown;
        }

        self.memberships = owned_memberships;
        for (entries.items) |entry| self.gpa.free(entry.path);
        entries.deinit(self.gpa);

        // A content change found during this rebuild invalidates only roots
        // that actually contain the changed file.
        var changed_it = refreshed.iterator();
        while (changed_it.next()) |entry| {
            if (!entry.value_ptr.changed) continue;
            // An open/injected overlay is authoritative; a disk change must
            // not invalidate roots whose analysis uses the overlay text.
            if (self.hasOverlayPath(entry.key_ptr.*)) continue;
            self.content_generation += 1;
            try self.bumpRootsForPath(entry.key_ptr.*);
        }
    }

    fn hasOverlayPath(self: *const Store, source_path: []const u8) bool {
        return self.buffers.contains(source_path) or self.injected.contains(source_path);
    }

    fn freeMemberships(self: *Store) void {
        for (self.memberships) |membership| {
            if (membership.containing_roots.len > 0) self.gpa.free(membership.containing_roots);
            if (membership.dependants.len > 0) self.gpa.free(membership.dependants);
        }
        if (self.memberships.len > 0) self.gpa.free(self.memberships);
        self.memberships = &.{};
    }

    fn freeMembershipIndex(self: *Store) void {
        var it = self.membership_index.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.len > 0) self.gpa.free(entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.membership_index.deinit(self.gpa);
        self.membership_index = .{};
    }

    fn refreshSource(self: *Store, source_path: []const u8) !SourceRefresh {
        const previous_hash: ?[32]u8 = if (self.sources.get(source_path)) |record| record.hash else null;

        const text = self.provider.readText(self.gpa, source_path) catch {
            const changed = if (self.sources.fetchRemove(source_path)) |entry| blk: {
                self.gpa.free(entry.key);
                self.gpa.free(entry.value.text);
                break :blk true;
            } else false;
            return .{ .status = .unreadable, .changed = changed };
        };
        errdefer self.gpa.free(text);

        const hash = types.contentHash(text);
        const changed = if (previous_hash) |old| !std.mem.eql(u8, &old, &hash) else true;
        if (self.sources.getPtr(source_path)) |record| {
            self.gpa.free(record.text);
            record.text = text;
            record.hash = hash;
        } else {
            const owned_path = try self.gpa.dupe(u8, source_path);
            errdefer self.gpa.free(owned_path);
            try self.sources.put(self.gpa, owned_path, .{ .text = text, .hash = hash });
        }
        return .{ .status = .readable, .changed = changed };
    }

    fn pathKey(self: *Store, uri: []const u8) ![]u8 {
        if (try path_mod.fileUriToPath(self.gpa, uri)) |decoded| {
            defer self.gpa.free(decoded);
            return path_mod.normalizeLexical(self.gpa, decoded);
        }
        return path_mod.normalizeLexical(self.gpa, uri);
    }

    fn dupeU32(self: *Store, values: []const u32) ![]const u32 {
        if (values.len == 0) return &.{};
        return self.gpa.dupe(u32, values);
    }
};

fn isDocumentPath(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), discovery.marker_name) or
        std.mem.endsWith(u8, path, ".sjon");
}

fn resolveFile(allocator: Allocator, document_path: []const u8, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return path_mod.normalizeLexical(allocator, relative);
    }
    const dir = std.fs.path.dirname(document_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, relative });
    defer allocator.free(joined);
    return path_mod.normalizeLexical(allocator, joined);
}

/// Mark `start` and every fragment reachable from it through `:imports` in
/// `visited`. Iterative; a cycle terminates because each part is visited once.
fn markClosure(
    gpa: Allocator,
    program_value: *const types.Program,
    start: u32,
    visited: []bool,
) !void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, start);
    while (stack.pop()) |index| {
        if (index >= program_value.parts.len or visited[index]) continue;
        visited[index] = true;
        for (program_value.parts[index].imports) |import_ref| {
            const fragment = program_value.findFragment(import_ref.name) orelse continue;
            if (!visited[fragment]) try stack.append(gpa, fragment);
        }
    }
}
