//! Incremental Text Sync: apply LSP didChange ranges to a document
//! and reconcile the cached parse + analysis. The fast trivia-only
//! shortcut keeps the analysis cache hot across whitespace edits.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Range = Handler.Range;
const Document = Handler.Document;

/// Apply an incremental text change to an open document.
/// The range specifies which portion of the source to replace.
///
/// Fast path: if the edit only affects trivia (whitespace / comments),
/// the cached `AnalysisResult` is left in place — the source bytes are
/// updated but no validator work is scheduled. Semantic edits fall back
/// to the classic invalidate-and-reanalyze behavior.
pub fn changeDocumentIncremental(handler: *Handler, uri: []const u8, range: Range, text: []const u8) !void {
    const doc = handler.documents.getPtr(uri) orelse return;
    const old_source = doc.source;

    const start = Handler.lspPositionToOffset(old_source, range.start) orelse {
        handler.invalidateAnalysis(uri);
        return;
    };
    const end = Handler.lspPositionToOffset(old_source, range.end) orelse {
        handler.invalidateAnalysis(uri);
        return;
    };
    if (end < start) {
        handler.invalidateAnalysis(uri);
        return;
    }

    // Build new source: source[0..start] ++ text ++ source[end..]
    const new_len = start + text.len + (old_source.len - end);
    const new_source = try handler.gpa.alloc(u8, new_len);
    errdefer handler.gpa.free(new_source);
    @memcpy(new_source[0..start], old_source[0..start]);
    @memcpy(new_source[start..][0..text.len], text);
    @memcpy(new_source[start + text.len ..], old_source[end..]);

    // Classify before swapping: if non-trivia tokens didn't change, the
    // cached analysis is still correct against the new source (analysis
    // holds its own sentinel-terminated source copy and AST byte offsets
    // remain valid because they index into `doc.analysis_source`, not
    // `doc.source`). Just swap buffers.
    const old_z = handler.gpa.dupeZ(u8, old_source) catch null;
    defer if (old_z) |z| handler.gpa.free(z);
    const new_z = handler.gpa.dupeZ(u8, new_source) catch null;
    defer if (new_z) |z| handler.gpa.free(z);

    const classification: wgslender.Incremental.EditKind = blk: {
        if (old_z == null or new_z == null) break :blk .semantic;
        break :blk wgslender.Incremental.classifyEdit(handler.gpa, old_z.?, new_z.?) catch .semantic;
    };

    switch (classification) {
        .no_op => {
            // Textually identical — discard the (byte-identical) new buffer
            // and skip the reparse pipeline entirely. `doc.parse` stays
            // pointing at the unchanged tree; cache stays hot.
            handler.gpa.free(new_source);
            return;
        },
        .trivia_only => {
            // Keep the cached analysis — module_version preservation in
            // `updateParseAfterEdit` will honor this when the trivia
            // shortcut fires. If the reparse takes a non-shortcut path,
            // the version bump will invalidate the cache.
            handler.gpa.free(doc.source);
            doc.source = new_source;
        },
        .semantic => {
            // Analysis invalidation is handled by `updateParseAfterEdit`
            // (it runs before `prev.deinit` so cached pointers into
            // `prev.arena` get freed at the right time). Just swap the
            // source bytes here.
            handler.gpa.free(doc.source);
            doc.source = new_source;
        },
    }

    // Keep `doc.parse` (CST + AST) in sync with `doc.source`. The
    // `module_version` on the returned result tells us whether the
    // cached analysis can survive (trivia shortcut → preserved; any
    // other path → invalidated before `prev` is torn down).
    updateParseAfterEdit(handler, doc, .{
        .start = @intCast(start),
        .end = @intCast(end),
        .new_text = text,
    });
    // Magic-comment scan reads `doc.source` directly; re-run after any
    // source mutation so the cached layer tracks the current document.
    handler.rebuildMagic(doc);
}

fn updateParseAfterEdit(handler: *Handler, doc: *Document, edit: wgslender.Incremental.Edit) void {
    if (doc.parse) |*prev| {
        const prev_version = prev.module_version;
        const updated = wgslender.Incremental.reparse(handler.gpa, prev, edit) catch {
            // Reparse failed — the analysis (if any) held pointers into
            // `prev.arena`, which is about to be deinit'd. Invalidate
            // first so we don't leave a dangling cache.
            handler.invalidateAnalysisAt(doc);
            prev.deinit();
            doc.parse = null;
            return;
        };

        if (updated.module_version != prev_version) {
            // Any non-trivia-shortcut path bumps module_version. The
            // cached symbol/struct/expr types all index off the module
            // whose layout has changed; drop the cache before `prev`
            // (and therefore prev.arena) is torn down.
            handler.invalidateAnalysisAt(doc);
        } else if (doc.analysis) |a| {
            // Trivia shortcut fired. `module.source` got repointed at
            // the new arena-owned bytes (see `tryTriviaOnlyShortcut`),
            // but the cached diagnostics still reference the pre-edit
            // bytes for line/column rendering. Rebuild the line index
            // against the new source so future diagnostic formatting
            // produces correct coordinates.
            if (a._arena) |*ana_arena| {
                const ana_alloc = ana_arena.allocator();
                a.diagnostics.source = updated.module.source;
                a.diagnostics.line_index.deinit(ana_alloc);
                if (wgslender.Diagnostic.LineIndex.init(ana_alloc, updated.module.source)) |idx| {
                    a.diagnostics.line_index = idx;
                } else |_| {
                    // Line-index rebuild failed — safest to drop the
                    // cache rather than leave a half-updated one.
                    handler.invalidateAnalysisAt(doc);
                }
            }
        }

        prev.deinit();
        doc.parse = updated;
        return;
    }
    handler.rebuildParse(doc);
}
