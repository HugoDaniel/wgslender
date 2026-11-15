//! pngine public Zig API tests (pngine-shaders phase 05, Task 5).
//!
//! Everything here drives the experimental consumer facade
//! (`wgslender.Pngine`) alone — `Store.init(gpa, provider)`, discovery
//! through the store, `Pngine.assembleRoot`, `Pngine.mapDiagnostics`,
//! `Pngine.remapSourceMap` — with the in-memory provider from
//! `pngine_test_provider.zig`. No test reads project text from the host
//! filesystem, and no CLI/LSP module is imported: this file is the
//! third-party consumer the facade is written for.
//!
//! The ownership assertions are the ruling's contract: both one-shot
//! results deep-own their contents in one arena, stay valid and readable
//! after the store that produced them is deinitialized, and release with
//! exactly one `deinit()` call. `assembleRoot`'s pointer is store-owned
//! (the caller never frees it), proven by pointer stability across a
//! repeat assembly and across assembling an unrelated root.

const std = @import("std");
const testing = std.testing;
const wgslender = @import("wgslender");
const provider_mod = @import("pngine_test_provider.zig");

const Pngine = wgslender.Pngine;
const Diagnostic = wgslender.Diagnostic;
const SourceMap = wgslender.SourceMap;

const program_text =
    \\(wgsl :name lib :file "lib.wgsl")
    \\(shader-module :name main :file "root.wgsl" :imports [lib])
    \\(shader-module :name other :file "other.wgsl")
;

const lib_text = "fn lib_helper() -> f32 { return 1.0; }\n";
const root_text = "fn fs() -> f32 { return lib_helper(); }\n";
const other_text = "fn other_fn() -> f32 { return 2.0; }\n";

fn addFixture(provider: *provider_mod.FakeProvider) !void {
    try provider.addFile("/ws/api/program.sjon", program_text);
    try provider.addFile("/ws/api/lib.wgsl", lib_text);
    try provider.addFile("/ws/api/root.wgsl", root_text);
    try provider.addFile("/ws/api/other.wgsl", other_text);
}

fn rootByName(store: *Pngine.Store, program_id: Pngine.ProgramId, name: []const u8) !Pngine.RootId {
    const program = store.program(program_id) orelse return error.NoProgram;
    for (program.parts, 0..) |part, index| {
        if (part.isRoot() and std.mem.eql(u8, part.name, name)) {
            return .{ .program = program_id, .index = @intCast(index) };
        }
    }
    return error.RootNotFound;
}

fn offsetOf(haystack: []const u8, needle: []const u8) !u32 {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return error.NeedleNotFound;
    return @intCast(index);
}

/// Assembled-coordinate range. Only the byte offsets are meaningful to
/// the projector; line/column ride along from the caller's own view of
/// the assembled text and are replaced by author positions in the result.
fn assembledRange(start: u32, end: u32) Diagnostic.Range {
    return .{
        .start = .{ .offset = start, .line = 1, .column = 1 },
        .end = .{ .offset = end, .line = 1, .column = 1 },
    };
}

test "facade drives discovery to owned diagnostics and a owned source map" {
    const a = testing.allocator;
    var provider = provider_mod.FakeProvider.init(a);
    defer provider.deinit();
    try addFixture(&provider);

    var mapped: Pngine.MappedDiagnostics = undefined;
    var remapped: Pngine.RemappedSourceMap = undefined;

    {
        var store = Pngine.Store.init(a, provider.sourceProvider());
        defer store.deinit();

        // Discovery through the facade's store and the injected provider.
        const workspace = [_][]const u8{"/ws/api"};
        try store.setWorkspaceRoots(&workspace);
        const program_id = store.programForDocument("/ws/api/program.sjon") orelse
            return error.NoProgram;
        const main_root = try rootByName(&store, program_id, "main");
        const other_root = try rootByName(&store, program_id, "other");

        // assembleRoot returns a store-owned unit: the caller never
        // frees it. Assembling an unrelated root must not move the
        // pointer, and a repeat call returns the same cached unit.
        const assembled = try Pngine.assembleRoot(&store, main_root);
        _ = try Pngine.assembleRoot(&store, other_root);
        try testing.expectEqual(assembled, try Pngine.assembleRoot(&store, main_root));
        try testing.expect(assembled.text.len > 0);

        const lib_off = try offsetOf(assembled.text, "lib_helper");
        const fs_off = try offsetOf(assembled.text, "fn fs");

        // --- mapDiagnostics over assembled-coordinate entries ----------
        const fix = Diagnostic.Fix{
            .range = assembledRange(lib_off, lib_off + @as(u32, "lib_helper".len)),
            .text = "renamed_helper",
        };
        const related = [1]Diagnostic.RelatedInfo{.{
            .range = assembledRange(fs_off, fs_off + @as(u32, "fn".len)),
            .message = "used here",
        }};
        const entries = [_]Diagnostic.Entry{
            .{
                .severity = .@"error",
                .code = "E0200",
                .message = "cannot resolve type",
                .range = assembledRange(lib_off, lib_off + @as(u32, "lib".len)),
                .related = &related,
                .fix = &fix,
            },
            // A range crossing the lib/root boundary has no honest
            // author range: the entry is dropped and the projection's
            // context-incomplete warning appears instead of a fabricated
            // location.
            .{
                .severity = .warning,
                .code = "W0001",
                .message = "unused",
                .range = assembledRange(0, @intCast(assembled.text.len)),
            },
        };
        mapped = try Pngine.mapDiagnostics(a, &store, assembled, &entries);

        // --- remapSourceMap over an assembled-coordinate map -----------
        // Minifier-shaped: generated positions are synthetic, source
        // positions are real assembled byte offsets.
        var gen = try SourceMap.Generator.init(a, assembled.text);
        defer gen.deinit();
        gen.setFile("main.min.wgsl");
        gen.setSourceName("assembled");
        gen.setCoverLinesWithoutMappings(false);
        try gen.addMapping(0, 0, fs_off, "fs");
        try gen.addMapping(1, 0, lib_off, "");
        const input_map = try gen.generate();

        remapped = try Pngine.remapSourceMap(a, &store, assembled, &input_map, .{
            .file = "main.min.wgsl",
            .include_sources_content = true,
        });
    }

    // The store is gone (scope above). Both results must remain fully
    // readable — the ruling's ownership contract — and one deinit must
    // release each of them.
    try testing.expectEqual(@as(usize, 2), mapped.items.len);

    const primary = mapped.items[0];
    try testing.expectEqualStrings("E0200", primary.code);
    try testing.expectEqualStrings("cannot resolve type", primary.message);
    try testing.expectEqualStrings("/ws/api/lib.wgsl", primary.origin.file);
    try testing.expectEqualStrings("/ws/api/program.sjon", primary.origin.project);
    try testing.expectEqualStrings("main", primary.origin.root);
    // "lib_helper" sits at byte 3 of lib.wgsl: author line 1, column 4.
    // A result left in assembled coordinates would carry the same offset
    // here only by coincidence of lib being assembled first.
    try testing.expectEqual(@as(u32, 3), primary.range.start.offset);
    try testing.expectEqual(@as(u32, 1), primary.range.start.line);
    try testing.expectEqual(@as(u32, 4), primary.range.start.column);
    // Related information is projected independently into root.wgsl.
    try testing.expectEqual(@as(usize, 1), primary.related.len);
    try testing.expectEqualStrings("/ws/api/root.wgsl", primary.related[0].file);
    try testing.expectEqual(@as(u32, 0), primary.related[0].range.start.offset);
    try testing.expectEqual(@as(u32, 1), primary.related[0].range.start.line);
    try testing.expectEqualStrings("used here", primary.related[0].message);
    // The fix survived with author coordinates and owned text.
    try testing.expect(primary.fix != null);
    try testing.expectEqual(@as(u32, 3), primary.fix.?.range.start.offset);
    try testing.expectEqual(@as(u32, 1), primary.fix.?.range.start.line);
    try testing.expectEqual(@as(u32, 4), primary.fix.?.range.start.column);
    try testing.expectEqualStrings("renamed_helper", primary.fix.?.text);

    const tail = mapped.items[1];
    try testing.expectEqualStrings("P0001", tail.code);
    try testing.expectEqual(Diagnostic.Severity.warning, tail.severity);
    try testing.expectEqualStrings("/ws/api/program.sjon", tail.origin.file);

    // The source map names the user's own files (`:file` spellings) in
    // first-use order, preserves generated positions and names verbatim,
    // and reports author-local source positions.
    try testing.expectEqualStrings("main.min.wgsl", remapped.map.file);
    try testing.expectEqual(@as(usize, 2), remapped.map.sources.len);
    try testing.expectEqualStrings("root.wgsl", remapped.map.sources[0]);
    try testing.expectEqualStrings("lib.wgsl", remapped.map.sources[1]);
    try testing.expectEqual(@as(usize, 2), remapped.map.sources_content.len);
    try testing.expectEqualStrings(root_text, remapped.map.sources_content[0]);
    try testing.expectEqualStrings(lib_text, remapped.map.sources_content[1]);
    try testing.expectEqual(@as(usize, 1), remapped.map.names.len);
    try testing.expectEqualStrings("fs", remapped.map.names[0]);
    try testing.expectEqual(@as(u32, 0), remapped.dropped);

    var decoded = try SourceMap.decodeMappings(a, remapped.map.mappings);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    // "fn fs" is line 1 of root.wgsl (0-based 0), "lib_helper" is line 1
    // of lib.wgsl. A map left in assembled coordinates would put the
    // root's text on a later line than 0.
    try testing.expectEqual(@as(u32, 0), decoded.items[0].src_index);
    try testing.expectEqual(@as(u32, 0), decoded.items[0].src_line);
    try testing.expectEqual(@as(u32, 0), decoded.items[0].src_col);
    try testing.expect(decoded.items[0].has_name);
    try testing.expectEqual(@as(i32, 0), decoded.items[0].name_index);
    try testing.expectEqual(@as(u32, 1), decoded.items[1].src_index);
    try testing.expectEqual(@as(u32, 0), decoded.items[1].src_line);
    try testing.expectEqual(@as(u32, 3), decoded.items[1].src_col);
    try testing.expect(!decoded.items[1].has_name);

    mapped.deinit();
    remapped.deinit();
}

test "assembleRoot returns exactly the ruling's AssemblyError members" {
    const a = testing.allocator;
    var provider = provider_mod.FakeProvider.init(a);
    defer provider.deinit();
    try provider.addFile("/ws/api/program.sjon", program_text);
    try provider.addFile("/ws/api/lib.wgsl", lib_text);
    try provider.addFile("/ws/api/root.wgsl", root_text);
    try provider.addFile("/ws/api/other.wgsl", other_text);

    var store = Pngine.Store.init(a, provider.sourceProvider());
    defer store.deinit();
    const workspace = [_][]const u8{"/ws/api"};
    try store.setWorkspaceRoots(&workspace);
    const program_id = store.programForDocument("/ws/api/program.sjon") orelse
        return error.NoProgram;

    try testing.expectError(
        error.UnknownProgram,
        Pngine.assembleRoot(&store, .{ .program = 9999, .index = 0 }),
    );
    try testing.expectError(
        error.UnknownPart,
        Pngine.assembleRoot(&store, .{ .program = program_id, .index = 99 }),
    );

    // A `wgsl` fragment is a part, not a root.
    const program = store.program(program_id).?;
    var lib_index: u32 = 0;
    for (program.parts, 0..) |part, index| {
        if (part.kind == .wgsl) lib_index = @intCast(index);
    }
    try testing.expectError(
        error.NotARoot,
        Pngine.assembleRoot(&store, .{ .program = program_id, .index = lib_index }),
    );

    // A part whose text the provider cannot read is MissingSource, never
    // a fabricated empty module.
    const main_root = try rootByName(&store, program_id, "main");
    provider.removeFile("/ws/api/lib.wgsl");
    store.invalidatePath("/ws/api/lib.wgsl");
    try testing.expectError(error.MissingSource, Pngine.assembleRoot(&store, main_root));
}

test "assembly graph failures surface as AssemblyError members" {
    const a = testing.allocator;
    var provider = provider_mod.FakeProvider.init(a);
    defer provider.deinit();
    try provider.addFile(
        "/ws/api/program.sjon",
        \\(wgsl :name a :file "a.wgsl" :imports [b])
        \\(wgsl :name b :file "b.wgsl" :imports [a])
        \\(shader-module :name cyc :file "root.wgsl" :imports [a])
        \\(shader-module :name bad :file "bad.wgsl" :imports [nope])
        ,
    );
    try provider.addFile("/ws/api/a.wgsl", "fn a_fn() -> f32 { return 1.0; }\n");
    try provider.addFile("/ws/api/b.wgsl", "fn b_fn() -> f32 { return 1.0; }\n");
    try provider.addFile("/ws/api/root.wgsl", root_text);
    try provider.addFile("/ws/api/bad.wgsl", "fn bad_fn() -> f32 { return 1.0; }\n");

    var store = Pngine.Store.init(a, provider.sourceProvider());
    defer store.deinit();
    const workspace = [_][]const u8{"/ws/api"};
    try store.setWorkspaceRoots(&workspace);
    const program_id = store.programForDocument("/ws/api/program.sjon") orelse
        return error.NoProgram;

    try testing.expectError(
        error.ImportCycle,
        Pngine.assembleRoot(&store, try rootByName(&store, program_id, "cyc")),
    );
    try testing.expectError(
        error.UnknownFragment,
        Pngine.assembleRoot(&store, try rootByName(&store, program_id, "bad")),
    );
}

test "mapDiagnostics propagates OOM and nothing else" {
    const a = testing.allocator;
    var provider = provider_mod.FakeProvider.init(a);
    defer provider.deinit();
    try addFixture(&provider);

    var store = Pngine.Store.init(a, provider.sourceProvider());
    defer store.deinit();
    const workspace = [_][]const u8{"/ws/api"};
    try store.setWorkspaceRoots(&workspace);
    const program_id = store.programForDocument("/ws/api/program.sjon") orelse
        return error.NoProgram;
    const main_root = try rootByName(&store, program_id, "main");
    const assembled = try Pngine.assembleRoot(&store, main_root);

    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const entries = [_]Diagnostic.Entry{.{
        .severity = .@"error",
        .code = "E0200",
        .message = "cannot resolve type",
        .range = assembledRange(0, 1),
    }};
    try testing.expectError(
        error.OutOfMemory,
        Pngine.mapDiagnostics(failing.allocator(), &store, assembled, &entries),
    );
}
