//! Per-root composed analysis for pngine shader projects (pngine-shaders
//! phase 03, Task 1).
//!
//! The Store owns discovery, text resolution, and byte-exact assembly; this
//! module owns the next layer up: running `Validator.analyze` over an
//! assembled root, retaining the borrowed `Assembled` for as long as the
//! result lives, and caching both under the Store's per-root content key.
//!
//! The module is pure code over `Store`/`Validator`: no `std.Io`, no native
//! provider, no filesystem. It is imported by `lsp/Handler.zig` in every
//! graph; the project-dependent declarations are compiled only when
//! `pngine_support` is true, so the wasm LSP graph still compiles with
//! `Pngine == void`.
//!
//! Cache validity has two stages:
//!   1. `(program revision, root revision, content generation)` is the cheap
//!      key. When it matches, the analysis is returned with no Store query.
//!   2. When it does not, ask `Store.assembleRoot` for the current unit. If
//!      the Store kept the same unit pointer (an unrelated root changed, or
//!      an edit-and-revert produced the same bytes), the existing analysis
//!      is still exactly right: adopt the new key and return the same
//!      objects. Only a different unit forces a rebuild.
//!
//! A rebuild is built completely before the old entry is released. If the
//! Store did replace the unit and the new analysis cannot be built, the old
//! entry is dropped rather than left pointing at a unit the Store may have
//! freed.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;

const Allocator = std.mem.Allocator;

/// A root's stable identity (`(program slot, source-order part index)`).
/// In graphs without project support this is just an opaque integer so the
/// Handler's no-op path still has a concrete signature.
pub const RootId = if (pngine_support) Pngine.RootId else u32;

/// One assembled root's validator result plus the borrowed assembly that
/// produced it. `input_generation` is the Store's root revision the result
/// was last verified against. The `assembled` pointer is owned by the
/// Store and stays valid exactly as long as the Store keeps that unit.
pub const RootAnalysis = if (pngine_support) RootAnalysisImpl else struct {};

const RootAnalysisImpl = struct {
    root: Pngine.RootId,
    assembled: *const Pngine.Assembled,
    result: *wgslender.Validator.AnalysisResult,
    /// Root revision at the last build or content-key adoption. Stable
    /// across edits to unrelated roots, which is what makes it useful for
    /// cache-identity assertions and later result IDs.
    input_generation: u64,
    key: CacheKey,
    /// Single-slot estimator cache, mirroring the per-document
    /// `Document.minify_cache`. Options are compared field-by-field; a
    /// different option set replaces the slot.
    minify: ?MinifySlot = null,

    fn deinit(self: *RootAnalysisImpl, gpa: Allocator) void {
        if (self.minify) |*slot| slot.deinit();
        self.result.deinit();
        gpa.destroy(self.result);
        gpa.destroy(self);
    }
};

/// The Store content key this analysis was built from. `content_generation`
/// is global (any project content change bumps it), so a mismatch is a
/// signal to ask the Store; the unit pointer decides whether a rebuild is
/// actually necessary.
const CacheKey = struct {
    program_revision: u64,
    root_revision: u64,
    content_generation: u64,

    fn eql(a: CacheKey, b: CacheKey) bool {
        return a.program_revision == b.program_revision and
            a.root_revision == b.root_revision and
            a.content_generation == b.content_generation;
    }
};

const MinifySlot = struct {
    arena: std.heap.ArenaAllocator,
    options: wgslender.MinifyEstimator.Options,
    result: wgslender.MinifyEstimator.EstimateResult,

    fn deinit(self: *MinifySlot) void {
        self.arena.deinit();
    }
};

/// The Handler-embedded cache. `SupportedState` in project graphs;
/// `UnsupportedState` keeps `Handler`'s field initializer and `deinit`
/// valid in the wasm graph, where no root can ever be analyzed.
pub const State = if (pngine_support) SupportedState else UnsupportedState;

const UnsupportedState = struct {
    pub fn deinit(_: *UnsupportedState, _: Allocator) void {}
    pub fn clear(_: *UnsupportedState, _: Allocator) void {}
};

const SupportedState = struct {
    cache: std.AutoHashMapUnmanaged(Pngine.RootId, *RootAnalysisImpl) = .{},

    pub fn deinit(self: *SupportedState, gpa: Allocator) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        self.cache.deinit(gpa);
    }

    /// Drop every cached analysis without touching the Store. Called when
    /// the Handler is rebound to a different (or no) Store.
    pub fn clear(self: *SupportedState, gpa: Allocator) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(gpa);
        self.cache.clearRetainingCapacity();
    }

    /// Return the analysis for `root`, rebuilding only when the Store's
    /// content key and the assembled unit both moved.
    pub fn analyzeRoot(
        self: *SupportedState,
        gpa: Allocator,
        store: *Pngine.Store,
        root: Pngine.RootId,
    ) !*RootAnalysisImpl {
        const program_revision = store.programRevision(root.program);
        const root_revision = store.rootRevision(root);
        const key: CacheKey = .{
            .program_revision = program_revision,
            .root_revision = root_revision,
            .content_generation = store.contentGeneration(),
        };

        if (self.cache.get(root)) |entry| {
            if (entry.key.eql(key)) return entry;
        }

        // The cheap key changed. Ask the Store for the unit it would use
        // now; a hit here rehashes cached text in the Store and performs no
        // provider read.
        const assembled = store.assembleRoot(root) catch |err| return err;

        if (self.cache.get(root)) |entry| {
            if (entry.key.program_revision == program_revision and entry.assembled == assembled) {
                // Same unit, new trigger generation (unrelated root edit,
                // edit-and-revert, content generation-only bump). Adopt the
                // key without reanalyzing.
                entry.key = key;
                entry.input_generation = root_revision;
                return entry;
            }
        }

        const replacement = buildAnalysis(gpa, root, assembled, key) catch |err| {
            self.dropStale(gpa, root, key, assembled);
            return err;
        };

        const gop = self.cache.getOrPut(gpa, root) catch |err| {
            replacement.deinit(gpa);
            self.dropStale(gpa, root, key, assembled);
            return err;
        };
        if (gop.found_existing) {
            const previous = gop.value_ptr.*;
            gop.value_ptr.* = replacement;
            previous.deinit(gpa);
        } else {
            gop.value_ptr.* = replacement;
        }
        return replacement;
    }

    /// Return the cached estimator result for this root, computing it once
    /// per `(analysis, options)` pair. A repeat request performs no
    /// estimation and, because `analyzeRoot` hits its key, no provider read.
    pub fn getMinifyEstimate(
        self: *SupportedState,
        gpa: Allocator,
        store: *Pngine.Store,
        root: Pngine.RootId,
        options: wgslender.MinifyEstimator.Options,
    ) !*const wgslender.MinifyEstimator.EstimateResult {
        const analysis = try self.analyzeRoot(gpa, store, root);
        const module = analysis.result.module orelse return error.NoModule;

        if (analysis.minify) |*slot| {
            if (optionsEql(slot.options, options)) return &slot.result;
            slot.deinit();
            analysis.minify = null;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const result = wgslender.MinifyEstimator.estimate(arena.allocator(), module, options) catch
            return error.OutOfMemory;

        analysis.minify = .{
            .arena = arena,
            .options = options,
            .result = result,
        };
        return &analysis.minify.?.result;
    }

    /// Release an entry whose `Assembled` the Store may have replaced. The
    /// Store owns `assembled`; this only frees the analysis result and its
    /// estimate slot.
    fn dropStale(
        self: *SupportedState,
        gpa: Allocator,
        root: Pngine.RootId,
        key: CacheKey,
        assembled: *const Pngine.Assembled,
    ) void {
        const previous = self.cache.get(root) orelse return;
        if (previous.key.program_revision == key.program_revision and
            previous.assembled == assembled)
        {
            return;
        }
        if (self.cache.fetchRemove(root)) |removed| removed.value.deinit(gpa);
    }
};

fn optionsEql(
    a: wgslender.MinifyEstimator.Options,
    b: wgslender.MinifyEstimator.Options,
) bool {
    return a.mangle_external_bindings == b.mangle_external_bindings and
        a.sort_declarations == b.sort_declarations and
        a.scope_local_rename == b.scope_local_rename and
        a.tree_shaking == b.tree_shaking and
        a.use_full_minify == b.use_full_minify;
}

/// Parse and validate the assembled text, then attach DCE/liveness exactly
/// as `Handler.analyzeFromParse` does. One arena owns the copied source,
/// the AST module, the diagnostics, and the liveness bit-set, so the whole
/// result has a single lifetime: the returned `RootAnalysis`.
fn buildAnalysis(
    gpa: Allocator,
    root: Pngine.RootId,
    assembled: *const Pngine.Assembled,
    key: CacheKey,
) !*RootAnalysisImpl {
    // The assembly-to-analysis pipeline is shared with the CLI
    // (`Pngine.Analysis`); this cache owns only invalidation and retention.
    const analyzed = try Pngine.Analysis.analyze(gpa, assembled, .{});
    return adopt(gpa, root, assembled, key, analyzed);
}

/// Move a finished analysis value into its heap-owned box. The analysis
/// owns its arena; if either allocation below fails, the arena must be
/// released here rather than leaked. Ownership is transferred by clearing
/// `_arena` once the value is stored in its heap box.
fn adopt(
    gpa: Allocator,
    root: Pngine.RootId,
    assembled: *const Pngine.Assembled,
    key: CacheKey,
    analysis: wgslender.Validator.AnalysisResult,
) !*RootAnalysisImpl {
    var owned = analysis;
    errdefer owned.deinit();

    const result = try gpa.create(wgslender.Validator.AnalysisResult);
    errdefer gpa.destroy(result);
    const entry = try gpa.create(RootAnalysisImpl);
    errdefer gpa.destroy(entry);

    // Both owners exist; transfer the arena to the box so the local's
    // errdefer cannot free it a second time.
    result.* = owned;
    owned._arena = null;
    entry.* = .{
        .root = root,
        .assembled = assembled,
        .result = result,
        .input_generation = key.root_revision,
        .key = key,
    };
    return entry;
}
