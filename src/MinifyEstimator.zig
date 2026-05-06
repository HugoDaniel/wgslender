//! Fast byte-size estimator for minified WGSL output.
//!
//! Two paths:
//!   * Cheap (default, Phase 3): dry-run Printer + `LengthRenamer` that
//!     returns 'x'-filled slices whose lengths match what the real
//!     `MinifyRenamer` would have assigned. Since the Printer is the
//!     authority on minified output, `total_min` matches
//!     `Minifier.minify(...).code.len` exactly on well-formed shaders.
//!     `total_gz` uses the documented heuristic `total_min * 0.35`.
//!   * Full-minify (Phase 8, opt-in via `Options.use_full_minify`): runs
//!     the production `MinifyRenamer` end-to-end so the printed output
//!     contains real names, then gzip-encodes it for an exact `total_gz`.
//!     Slower in exchange for ground truth — the LSP exposes this as a
//!     workspace setting and per-document cache invalidates correctly
//!     because the heavy path participates in the same module-version
//!     cache key as the cheap path.
//!
//! Mutation policy: the estimator does NOT permanently mutate the
//! module's symbol table OR its `use_counts` / `liveness` side-tables.
//! Every estimator call allocates its own per-call `UseCounts`,
//! `Liveness`, and `RenamePolicy`, runs the analysis there, and
//! discards them. The cached LSP module survives untouched so
//! subsequent estimator calls see the same starting state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Dce = @import("Dce.zig");
const Liveness = @import("Liveness.zig");
const Minifier = @import("Minifier.zig");
const Printer = @import("Printer.zig");
const Renamer = @import("Renamer.zig");
const RenamePolicy = @import("RenamePolicy.zig");
const UseCounts = @import("UseCounts.zig");

// =========================================================================
// Public API
// =========================================================================

pub const Options = struct {
    /// Rename `@group/@binding` vars. Mirrors `Minifier.Options.mangle_external_bindings`.
    mangle_external_bindings: bool = false,
    /// Sort module-level declarations by kind/size. Mirrors
    /// `Minifier.Options.sort_declarations`.
    sort_declarations: bool = false,
    /// Assign per-function canonical names to parameters and locals.
    /// Mirrors `Minifier.Options.scope_local_rename`.
    scope_local_rename: bool = false,
    /// Tree-shake unreachable declarations. Mirrors
    /// `Minifier.Options.tree_shaking`.
    tree_shaking: bool = true,
    /// Phase 8 — opt-in: replace the cheap length-only renamer with the
    /// production `MinifyRenamer` so output contains real names and
    /// `total_gz` reflects an actual gzip of the minified text instead
    /// of the `total_min * 0.35` heuristic. Slower; the LSP gates this
    /// behind `wgslender.minifyEstimator.useFullMinify`.
    use_full_minify: bool = false,
};

pub const PerFunction = struct {
    min: u32,
    gz: u32,
};

pub const PerDecl = struct {
    min: u32,
};

pub const EstimateResult = struct {
    total_min: u32,
    total_gz: u32,
    per_function: std.AutoHashMapUnmanaged(Ast.SymbolIndex, PerFunction),
    per_decl: std.AutoHashMapUnmanaged(Ast.SymbolIndex, PerDecl),
};

/// Gzip ratio heuristic. Replace with a BPE/histogram-based estimator when
/// the compile-pipeline integration lands; the public API stays the same.
const gz_ratio: f32 = 0.35;

/// Process-global counter of `estimate` calls. Bumped on every entry into
/// the estimator. Used by the LSP perf smoke test
/// (`tests/lsp_minify_perf_test.zig`) to prove that the per-document cache
/// in the Handler coalesces redundant estimator runs across inlay-hint /
/// code-lens / lint paths. Not thread-safe; tests are single-threaded.
pub var estimate_count: u64 = 0;

/// Estimate minified byte counts for `module` under the given options.
/// Allocations live in `arena`; the result becomes invalid when the arena
/// is deinit'd. Safe to call multiple times on the same module.
pub fn estimate(arena: Allocator, module: *Ast.Module, options: Options) !EstimateResult {
    estimate_count += 1;

    // Step 1: per-call Liveness — never mutates the cached
    // `module.liveness` so estimator runs are idempotent.
    var liveness = try Liveness.init(arena, module.symbols.items.len);
    if (options.tree_shaking) {
        _ = try Dce.mark(arena, module, &liveness);
    } else {
        liveness.markAllLive();
    }

    // Step 2: per-call UseCounts seeded from the module's canonical
    // counts. Pass-2 ident bumps live in `module.use_counts`;
    // `accumulateSymbolUseCounts` adds the post-pass call/decl bumps
    // into our local copy below — the cached module stays untouched.
    const use_counts_box = try arena.create(UseCounts);
    use_counts_box.* = try UseCounts.init(arena, module.symbols.items.len);
    const seed_n = @min(use_counts_box.counts.len, module.use_counts.counts.len);
    @memcpy(use_counts_box.counts[0..seed_n], module.use_counts.counts[0..seed_n]);

    // Step 3: per-call RenamePolicy. The estimator's hypothetical
    // analysis doesn't honor `keep_names` or
    // `preserve_uniform_struct_types` (preserved behavior — those are
    // LSP-driven minify-mode estimations that don't see those options
    // today); only the kind / external-binding marks apply.
    var builder = try RenamePolicy.Builder.init(arena, module.symbols.items.len);
    builder.markEntryPoints(module);
    builder.markBuiltinsAndOverrides(module);
    if (!options.mangle_external_bindings) builder.markExternalBindings(module);
    const policy_box = try arena.create(RenamePolicy);
    policy_box.* = builder.build();

    // Step 4: usage counts. Shared helper with the real minifier so rank
    // ordering is byte-identical.
    var uses = try Minifier.computeSymbolUsage(arena, module);
    defer uses.deinit(arena);

    // Step 5: reserved name set. Language keywords + every non-renameable
    // symbol's original name — the latter mirrors MinifyRenamer's
    // `reserveUnrenamedSymbolNames`, so the estimator doesn't pick a
    // short name that would collide with an un-renamed symbol.
    var reserved = try Renamer.computeReservedNames(arena);
    for (module.symbols.items, 0..) |*sym, i| {
        if (!isRenameable(@intCast(i), sym, policy_box, options)) {
            try reserved.put(arena, sym.original_name, {});
        }
    }

    // Step 6: build the renamer the Printer will route every identifier
    // through. The cheap path uses a `LengthRenamer` that emits
    // 'x'-filled slices of the right length; the full-minify path uses
    // the production `MinifyRenamer` directly so the buffered output
    // can be gzipped for an exact `total_gz`.
    const base_renamer: *const Printer.Renamer = if (options.use_full_minify)
        try buildMinifyRenamer(arena, module, &uses, reserved, use_counts_box, policy_box)
    else
        try buildLengthRenamer(arena, module, &uses, reserved, use_counts_box, policy_box, options);

    // Optional scope-local wrapping. Mirrors Minifier.printWithRenamer.
    // ScopeLocalRenamer produces real canonical names for locals/params;
    // their lengths match what a real minify run produces, so byte
    // counts stay accurate on either path.
    var active_renamer: *const Printer.Renamer = base_renamer;
    if (options.scope_local_rename) {
        const scope = try Minifier.ScopeLocalRenamer.init(arena, module, base_renamer, policy_box);
        active_renamer = &scope.ren;
    }

    // Step 5: Printer set up identically to the real minify's minimum
    // configuration (whitespace + identifier + syntax minification on,
    // tree-shaking from options). `sort_declarations` is handled by the
    // per-decl loop below.
    var printer = Printer.init(arena, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = if (options.sort_declarations) false else options.tree_shaking,
        .renamer = active_renamer,
    }, module.symbols.items);

    var result = EstimateResult{
        .total_min = 0,
        .total_gz = 0,
        .per_function = .empty,
        .per_decl = .empty,
    };

    // The full-minify path keeps every decl in the same buffer so the
    // accumulated bytes can be gzipped once at the end. The cheap path
    // clears the buffer between decls — its total is summed from the
    // per-decl sizes. Both produce identical per-decl byte counts; the
    // printer's `needs_space` flag is always false at decl boundaries
    // (each top-level decl ends with `;` or `}` which clears it), so
    // accumulation is byte-equivalent to the clear-and-print pattern.
    const accumulate = options.use_full_minify;

    // Directives first (enable/requires/diagnostic).
    for (module.directives.items) |dir| {
        const before: u32 = @intCast(printer.buf.items.len);
        if (!accumulate) printer.buf.clearRetainingCapacity();
        try printer.printDirective(dir);
        const after: u32 = @intCast(printer.buf.items.len);
        const size: u32 = if (accumulate) after - before else after;
        result.total_min += size;
    }

    // Declarations. When sort_declarations is on, use Minifier's sort
    // helper (already filters to live decls); otherwise iterate the
    // module's order and filter dead decls inline — matches
    // Printer.printModule's behaviour under tree_shaking.
    const decl_list: []const Ast.Decl = if (options.sort_declarations)
        try Minifier.sortDeclarations(arena, module)
    else
        module.declarations.items;

    for (decl_list) |decl| {
        if (!options.sort_declarations and options.tree_shaking) {
            if (!Dce.isDeclarationLive(decl, liveness)) continue;
        }

        const before: u32 = @intCast(printer.buf.items.len);
        if (!accumulate) printer.buf.clearRetainingCapacity();
        try printer.printDecl(decl);
        const after: u32 = @intCast(printer.buf.items.len);
        const size: u32 = if (accumulate) after - before else after;
        result.total_min += size;

        const name_ref = decl.nameRef();
        if (name_ref.isValid()) {
            try result.per_decl.put(arena, name_ref, .{ .min = size });
            if (decl == .function) {
                try result.per_function.put(arena, name_ref, .{
                    .min = size,
                    .gz = estimateGz(size),
                });
            }
        }
    }

    if (accumulate) {
        // Ground-truth gzip on the actual minified bytes. Falls back to
        // the heuristic on compress failure so callers keep a usable
        // figure even if the codec misbehaves.
        result.total_gz = gzipSize(arena, printer.buf.items) catch estimateGz(result.total_min);
    } else {
        result.total_gz = estimateGz(result.total_min);
    }
    return result;
}

// =========================================================================
// Internals
// =========================================================================

fn isRenameable(idx: u32, sym: *const Ast.Symbol, policy: *const RenamePolicy, options: Options) bool {
    if (policy.mustNotRename(@enumFromInt(idx))) return false;
    if (sym.flags.is_entry_point) return false;
    if (sym.kind == .builtin or sym.kind == .override) return false;
    if (sym.flags.is_external_binding and !options.mangle_external_bindings) return false;
    return true;
}

fn estimateGz(min: u32) u32 {
    return @intFromFloat(@as(f32, @floatFromInt(min)) * gz_ratio);
}

const LengthRenamer = struct {
    sym_lengths: []const u32,
    scratch: []const u8,
    ren: Printer.Renamer,
};

fn lengthRenamerNameFor(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
    const self: *const LengthRenamer = @ptrCast(@alignCast(ptr));
    if (!ref.isValid()) return "";
    const idx = ref.index();
    if (idx >= self.sym_lengths.len) return "";
    const len = self.sym_lengths[idx];
    if (len == 0) return "";
    return self.scratch[0..len];
}

/// Build the cheap path's length-only renamer. Allocates rank+length
/// arrays in `arena` and returns a pointer suitable for plugging into
/// `Printer.Options.renamer`.
fn buildLengthRenamer(
    arena: Allocator,
    module: *Ast.Module,
    uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
    reserved: std.StringHashMapUnmanaged(void),
    use_counts: *const UseCounts,
    policy: *const RenamePolicy,
    options: Options,
) !*const Printer.Renamer {
    // Rank renameable symbols by use_count DESC, breaking ties on
    // symbol index ASC. Same rule as MinifyRenamer.allocateSlots, with
    // the accumulate-use-counts step inlined: parser Pass 2 populated
    // the per-symbol entries in `use_counts.counts`, and
    // `computeSymbolUsage` adds references the parser didn't walk
    // (e.g., function-name call sites). Their sum is the quantity the
    // real renamer ranks against.
    const RankedSym = struct { idx: u32, count: u32 };
    var ranked: std.ArrayList(RankedSym) = .empty;
    for (module.symbols.items, 0..) |*sym, i| {
        if (!isRenameable(@intCast(i), sym, policy, options)) continue;
        const ref: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        const uses_delta = uses.get(ref) orelse 0;
        const pass2_count: u32 = if (i < use_counts.counts.len) use_counts.counts[i] else 0;
        const total_count = pass2_count + uses_delta;
        if (total_count == 0) continue;
        try ranked.append(arena, .{ .idx = @intCast(i), .count = total_count });
    }
    std.mem.sort(RankedSym, ranked.items, {}, struct {
        fn lessThan(_: void, a: RankedSym, b: RankedSym) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.idx < b.idx;
        }
    }.lessThan);

    // Per-rank lengths via the shared helper. Same skip-reserved-word
    // policy as MinifyRenamer.assignNames.
    var reserved_local = reserved;
    const rank_lengths = try arena.alloc(u32, ranked.items.len);
    Renamer.estimateRenameLength(&reserved_local, rank_lengths);

    // Per-symbol byte lengths. Non-ranked symbols (unused, non-
    // renameable) print their original name, so use its byte length.
    const sym_lengths = try arena.alloc(u32, module.symbols.items.len);
    for (module.symbols.items, 0..) |*sym, i| {
        sym_lengths[i] = @intCast(sym.original_name.len);
    }
    for (ranked.items, 0..) |rs, rank| {
        sym_lengths[rs.idx] = rank_lengths[rank];
    }

    // Scratch buffer the LengthRenamer slices into. Content is
    // irrelevant — Printer.emit just appends bytes and emitSpace
    // adjacency depends on token state, not identifier content.
    var max_len: u32 = 1;
    for (sym_lengths) |len| {
        if (len > max_len) max_len = len;
    }
    const scratch = try arena.alloc(u8, max_len);
    @memset(scratch, 'x');

    const length_renamer = try arena.create(LengthRenamer);
    length_renamer.* = .{
        .sym_lengths = sym_lengths,
        .scratch = scratch,
        .ren = undefined,
    };
    length_renamer.ren = .{
        .ptr = @ptrCast(length_renamer),
        .nameForSymbolFn = &lengthRenamerNameFor,
    };
    return &length_renamer.ren;
}

/// Build the full-minify path's renamer — the production
/// `MinifyRenamer`, configured exactly like `Minifier.minify` does.
/// `use_counts` is the per-call seeded copy from `estimate`;
/// `rename_policy` is the per-call policy. Neither outlives the
/// estimator run, so the cached module stays pristine.
fn buildMinifyRenamer(
    arena: Allocator,
    module: *Ast.Module,
    uses: *const std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
    reserved: std.StringHashMapUnmanaged(void),
    use_counts: *UseCounts,
    rename_policy: *const RenamePolicy,
) !*const Printer.Renamer {
    const r = try arena.create(Renamer.MinifyRenamer);
    r.* = Renamer.MinifyRenamer.init(arena, module.symbols.items, reserved);
    r.setSideTables(use_counts, rename_policy);
    r.accumulateSymbolUseCounts(uses);
    try r.allocateSlots();
    try r.reserveUnrenamedSymbolNames();
    try r.assignNames();
    r.renamer.ptr = @ptrCast(r);
    return &r.renamer;
}

/// gzip-encode `data` and return the compressed byte count. Used by the
/// full-minify path so `total_gz` reflects ground-truth compression of
/// the actual minified text instead of the cheap-path heuristic.
fn gzipSize(arena: Allocator, data: []const u8) !u32 {
    const flate = std.compress.flate;
    // Output capacity: gzip's worst case for incompressible data is
    // input + ~5 bytes per 64KB block + 18 bytes header/footer. A
    // generous `2 * len + 256` fits everything plus the empty-block
    // edge case.
    const out_capacity: usize = @max(data.len * 2 + 256, 256);
    const out_buf = try arena.alloc(u8, out_capacity);
    var out_w: std.Io.Writer = .fixed(out_buf);
    const deflate_buf = try arena.alloc(u8, flate.max_window_len);
    var deflate_w = try flate.Compress.init(&out_w, deflate_buf, .gzip, flate.Compress.Options.default);
    try deflate_w.writer.writeAll(data);
    try deflate_w.finish();
    return @intCast(out_w.end);
}

// =========================================================================
// Tests
// =========================================================================

test "estimate: empty module produces zero total" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Lexer = @import("Lexer.zig");
    const Parser = @import("Parser.zig");

    const source: [:0]const u8 = "";
    const tokens = try Lexer.tokenize(a, source);
    var parser = try Parser.init(a, source, tokens);
    const module = try parser.parse();

    const result = try estimate(a, module, .{});
    try std.testing.expectEqual(@as(u32, 0), result.total_min);
    try std.testing.expectEqual(@as(u32, 0), result.total_gz);
}

test "estimate: total_gz is 35% of total_min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Lexer = @import("Lexer.zig");
    const Parser = @import("Parser.zig");

    const source: [:0]const u8 = "fn main() {}";
    const tokens = try Lexer.tokenize(a, source);
    var parser = try Parser.init(a, source, tokens);
    const module = try parser.parse();

    const result = try estimate(a, module, .{});
    const expected: u32 = @intFromFloat(@as(f32, @floatFromInt(result.total_min)) * gz_ratio);
    try std.testing.expectEqual(expected, result.total_gz);
}
